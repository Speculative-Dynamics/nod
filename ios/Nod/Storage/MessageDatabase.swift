// MessageDatabase.swift
// SQLite persistence for the one continuous conversation with Nod.
//
// Schema:
//   messages        — every user/assistant/nod turn, ever.
//                     is_summarized flag tracks which messages have been
//                     rolled into the summary below.
//   summary         — singleton (id=1). The running compressed summary of
//                     every message where is_summarized=1. Updated in place
//                     when compression runs.
//
// There are no "sessions." One user, one ongoing conversation, forever.
// Compression prevents the context window from overflowing.

import Foundation
import GRDB

/// Thread-safe database handle. Created once at app launch, shared by
/// ConversationStore. All writes happen on GRDB's write queue; reads
/// on GRDB's read pool.
///
/// `@unchecked Sendable` is an honest claim here: the only stored
/// properties are `let queue: DatabaseQueue` (GRDB-documented thread-
/// safe) and `let databaseURL: URL` (immutable value type). There's no
/// mutable shared state, and all DB mutations funnel through the
/// thread-safe queue. Declaring Sendable lets `Task.detached`
/// closures capture a `MessageDatabase` reference without Swift 6
/// strict-concurrency errors — needed for the cold-launch hydration
/// path, which fetches off the main actor.
final class MessageDatabase: @unchecked Sendable {

    private static let iCloudBackupEnabledKey = "Storage.conversation.iCloudBackupEnabled"

    let queue: DatabaseQueue
    private let databaseURL: URL

    /// The on-disk location. Stored locally under Library/ and excluded
    /// from iCloud backup by default unless the user opts in.
    static let fileURL: URL = {
        let fm = FileManager.default
        let libraryURL = try! fm.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return libraryURL.appendingPathComponent("nod-conversation.sqlite")
    }()

    static var iCloudBackupEnabled: Bool {
        get {
            let defaults = UserDefaults.standard
            return defaults.object(forKey: iCloudBackupEnabledKey) as? Bool ?? false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: iCloudBackupEnabledKey)
        }
    }

    var isICloudBackupEnabled: Bool {
        Self.iCloudBackupEnabled
    }

    var pendingWritesURL: URL {
        databaseURL
            .deletingLastPathComponent()
            .appendingPathComponent("nod-conversation-pending-writes.json")
    }

    init(path: String? = nil) throws {
        self.databaseURL = path.map(URL.init(fileURLWithPath:)) ?? Self.fileURL
        self.queue = try DatabaseQueue(path: databaseURL.path)
        try runMigrations()
        try applyBackupPreference()
    }

    // MARK: - Migrations

    private func runMigrations() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "messages") { t in
                t.column("id", .text).primaryKey()
                t.column("role", .text).notNull()
                t.column("text", .text).notNull()
                t.column("created_at", .text).notNull()
                t.column("is_summarized", .boolean).notNull().defaults(to: false)
            }
            try db.create(indexOn: "messages", columns: ["created_at"])
            try db.create(indexOn: "messages", columns: ["is_summarized"])

            try db.create(table: "summary") { t in
                t.column("id", .integer).primaryKey()
                t.column("text", .text).notNull()
                t.column("updated_at", .text).notNull()
            }
        }

        // v2: structured entity memory.
        // Stores people / places / projects / situations the user has
        // mentioned, so Nod can inject relevant context into future
        // inferences without the user needing to re-explain "who is M."
        // See design doc (Phase 2) for the product intent; see EntityStore
        // and EntityExtractorService for the write/read paths.
        //
        // `embedding` is a BLOB of Float32 values — the NLEmbedding
        // sentence vector of `canonical_name + role + notes`. Nullable
        // because NLEmbedding can fail (unsupported language, etc.) and
        // we still want to store the entity; keyword match handles the
        // retrieval when embedding is absent.
        migrator.registerMigration("v2_entities") { db in
            try db.create(table: "entities") { t in
                t.column("id", .text).primaryKey()
                t.column("type", .text).notNull()
                t.column("canonical_name", .text).notNull()
                t.column("role", .text)
                t.column("notes", .text).notNull().defaults(to: "")
                t.column("first_mentioned_at", .text).notNull()
                t.column("last_mentioned_at", .text).notNull()
                t.column("mention_count", .integer).notNull().defaults(to: 1)
                t.column("embedding", .blob)
            }
            try db.create(indexOn: "entities", columns: ["canonical_name"])

            try db.create(table: "entity_aliases") { t in
                t.column("entity_id", .text).notNull()
                    .references("entities", onDelete: .cascade)
                t.column("alias", .text).notNull()
                t.primaryKey(["entity_id", "alias"])
            }
            try db.create(indexOn: "entity_aliases", columns: ["alias"])
        }

        // v3: wasCancelled flag for assistant messages the user stopped
        // mid-stream. Persists the "stopped" tag across relaunches.
        // INTEGER with default 0 keeps existing rows valid; SQLite has
        // no boolean type so we use INTEGER and treat it as 0/1.
        migrator.registerMigration("v3_was_cancelled") { db in
            try db.alter(table: "messages") { t in
                t.add(column: "was_cancelled", .integer).notNull().defaults(to: 0)
            }
        }

        // v4: per-message entity-extraction watermark. Decouples memory
        // creation from summarization — incremental extraction fires after
        // every reply instead of only at the 12-message compression mark,
        // so memories like "I have a dog named Rex" surface in the sidebar
        // within seconds of being mentioned.
        //
        // TEXT column (ISO8601 timestamp) rather than a plain boolean:
        // preserves when-it-happened for future debugging / analytics, and
        // matches the `created_at` / `updated_at` pattern used elsewhere.
        // NULL means "never extracted"; any timestamp means "done."
        //
        // Backfill: existing summarized rows were already run through
        // compression's parallel entity-extraction pass before this
        // release, so we mark them as extracted. Without this, the first
        // post-upgrade trigger would re-process up to BATCH_SIZE old rows
        // per cycle and waste LLM calls on already-extracted content.
        // Pre-compute the backfill timestamp outside the closure. The
        // migration closure is @escaping so capturing `self.iso8601(...)`
        // from inside would need explicit-self; passing the value in
        // keeps the closure value-capture-only.
        let v4BackfillTimestamp = iso8601(Date())
        migrator.registerMigration("v4_entities_extracted") { db in
            try db.alter(table: "messages") { t in
                t.add(column: "entities_extracted_at", .text)
            }
            try db.create(
                indexOn: "messages",
                columns: ["entities_extracted_at"]
            )
            try db.execute(sql: """
                UPDATE messages
                   SET entities_extracted_at = ?
                 WHERE is_summarized = 1
                """,
                arguments: [v4BackfillTimestamp]
            )
        }

        try migrator.migrate(queue)
    }

    // MARK: - Messages

    /// Append a new message.
    func insert(_ message: Message) throws {
        try queue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO messages (id, role, text, created_at, is_summarized, was_cancelled)
                VALUES (?, ?, ?, ?, 0, ?)
                """,
                arguments: [
                    message.id.uuidString,
                    message.role.rawValue,
                    message.text,
                    iso8601(message.createdAt),
                    message.wasCancelled ? 1 : 0
                ]
            )
        }
        try applyBackupPreference()
    }

    /// Update the text of an existing message (used for streaming AI replies).
    func updateText(id: UUID, text: String) throws {
        try queue.write { db in
            try db.execute(
                sql: "UPDATE messages SET text = ? WHERE id = ?",
                arguments: [text, id.uuidString]
            )
        }
        try applyBackupPreference()
    }

    /// Mark a message as cancelled (or clear the flag). Used when the user
    /// taps stop mid-stream, to persist the "stopped" tag across relaunches.
    func setCancelled(id: UUID, cancelled: Bool) throws {
        try queue.write { db in
            try db.execute(
                sql: "UPDATE messages SET was_cancelled = ? WHERE id = ?",
                arguments: [cancelled ? 1 : 0, id.uuidString]
            )
        }
        try applyBackupPreference()
    }

    /// Delete a message by ID. Used when the user regenerates a reply
    /// (old assistant message vanishes after the new one lands) or cancels
    /// before a single token streamed in (empty placeholder). No-op if
    /// the id doesn't exist.
    func deleteMessage(id: UUID) throws {
        try queue.write { db in
            try db.execute(
                sql: "DELETE FROM messages WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
        try applyBackupPreference()
    }

    /// All messages, oldest first. Used once on app launch to populate the
    /// in-memory view model.
    func fetchAllMessages() throws -> [Message] {
        try queue.read { db in
            let rows = try Row.fetchAll(db,
                sql: "SELECT id, role, text, created_at, was_cancelled FROM messages ORDER BY created_at ASC"
            )
            return rows.compactMap(messageFromRow)
        }
    }

    /// Diagnostic: raw row count in the entities table. Bypasses the
    /// entityFromRow decoder (which can drop rows if parsing fails) so
    /// we can tell "row in DB" from "row in in-memory array". Used by
    /// EntityStore.hydrate to surface persistence-layer bugs.
    func entitiesRowCount() throws -> Int {
        try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entities") ?? 0
        }
    }

    /// Un-summarized messages only, oldest first. Used to build the context
    /// window for the LLM (summary + these).
    func fetchUnsummarizedMessages() throws -> [Message] {
        try queue.read { db in
            let rows = try Row.fetchAll(db,
                sql: """
                    SELECT id, role, text, created_at, was_cancelled
                    FROM messages
                    WHERE is_summarized = 0
                    ORDER BY created_at ASC
                    """
            )
            return rows.compactMap(messageFromRow)
        }
    }

    /// Count of un-summarized messages. Cheap — used to decide when to
    /// trigger compression.
    func unsummarizedCount() throws -> Int {
        try queue.read { db in
            try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM messages WHERE is_summarized = 0"
            ) ?? 0
        }
    }

    /// Oldest N un-summarized messages. Used when compression runs.
    func fetchOldestUnsummarized(limit: Int) throws -> [Message] {
        try queue.read { db in
            let rows = try Row.fetchAll(db,
                sql: """
                    SELECT id, role, text, created_at, was_cancelled
                    FROM messages
                    WHERE is_summarized = 0
                    ORDER BY created_at ASC
                    LIMIT ?
                    """,
                arguments: [limit]
            )
            return rows.compactMap(messageFromRow)
        }
    }

    /// Mark messages as summarized after they've been rolled into the summary.
    func markSummarized(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try queue.write { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
            let args: [DatabaseValueConvertible] = ids.map { $0.uuidString }
            try db.execute(
                sql: "UPDATE messages SET is_summarized = 1 WHERE id IN (\(placeholders))",
                arguments: StatementArguments(args)
            )
        }
        try applyBackupPreference()
    }

    /// Oldest N messages that have NOT been run through entity extraction yet.
    /// Used by the incremental extraction path in ConversationStore — fires
    /// after every completed exchange so "Rex" surfaces as a memory within
    /// seconds of being mentioned, not after 12 messages of latency.
    ///
    /// `entities_extracted_at IS NULL` is the watermark: rows written before
    /// v4 migration were backfilled (summarized rows marked done); rows
    /// written post-migration start NULL until the incremental or compression
    /// path flips them.
    func fetchUnextractedMessages(limit: Int) throws -> [Message] {
        try queue.read { db in
            let rows = try Row.fetchAll(db,
                sql: """
                    SELECT id, role, text, created_at, was_cancelled
                    FROM messages
                    WHERE entities_extracted_at IS NULL
                    ORDER BY created_at ASC
                    LIMIT ?
                    """,
                arguments: [limit]
            )
            return rows.compactMap(messageFromRow)
        }
    }

    /// Mark messages as entity-extracted. Idempotent — setting the column
    /// on a row that already has a timestamp is a plain UPDATE that just
    /// rewrites the same value, so repeated calls (e.g. incremental running
    /// over a row compression already marked) are safe.
    func markEntitiesExtracted(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try queue.write { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
            var args: [DatabaseValueConvertible] = [iso8601(Date())]
            args.append(contentsOf: ids.map { $0.uuidString })
            try db.execute(
                sql: """
                    UPDATE messages
                       SET entities_extracted_at = ?
                     WHERE id IN (\(placeholders))
                    """,
                arguments: StatementArguments(args)
            )
        }
        try applyBackupPreference()
    }

    /// Atomic mark-summarized AND mark-extracted in one transaction. Used
    /// at the end of the compression pass so a crash between the two writes
    /// can't leave `is_summarized = 1` with `entities_extracted_at = NULL`
    /// — a state that would cause the next launch's incremental trigger to
    /// re-extract the already-processed batch.
    ///
    /// Replaces the pair `markSummarized(ids:)` + `markEntitiesExtracted(ids:)`
    /// at compression time. Both of those still exist for their individual
    /// use cases (tests; incremental-only path).
    func markCompressed(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try queue.write { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
            let idArgs: [DatabaseValueConvertible] = ids.map { $0.uuidString }

            // UPDATE 1: mark summarized
            try db.execute(
                sql: "UPDATE messages SET is_summarized = 1 WHERE id IN (\(placeholders))",
                arguments: StatementArguments(idArgs)
            )

            // UPDATE 2: mark extracted with current timestamp
            var extractedArgs: [DatabaseValueConvertible] = [iso8601(Date())]
            extractedArgs.append(contentsOf: idArgs)
            try db.execute(
                sql: """
                    UPDATE messages
                       SET entities_extracted_at = ?
                     WHERE id IN (\(placeholders))
                    """,
                arguments: StatementArguments(extractedArgs)
            )
        }
        try applyBackupPreference()
    }

    // MARK: - Summary

    /// Current running summary text. Empty string if nothing has been
    /// summarized yet.
    func fetchSummary() throws -> String {
        try queue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT text FROM summary WHERE id = 1")
            return row?["text"] as? String ?? ""
        }
    }

    /// Replace (or create) the running summary.
    func setSummary(_ text: String) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO summary (id, text, updated_at) VALUES (1, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET text = excluded.text, updated_at = excluded.updated_at
                    """,
                arguments: [text, iso8601(Date())]
            )
        }
        try applyBackupPreference()
    }

    // MARK: - Entities

    /// Insert or update an entity plus its aliases. Idempotent: upserts
    /// on primary key. Aliases are replaced wholesale for the entity.
    /// Wrapped in a transaction so the row + its aliases are always
    /// consistent.
    func upsertEntity(_ entity: Entity) throws {
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO entities
                    (id, type, canonical_name, role, notes,
                     first_mentioned_at, last_mentioned_at, mention_count, embedding)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    type               = excluded.type,
                    canonical_name     = excluded.canonical_name,
                    role               = excluded.role,
                    notes              = excluded.notes,
                    last_mentioned_at  = excluded.last_mentioned_at,
                    mention_count      = excluded.mention_count,
                    embedding          = excluded.embedding
                """,
                arguments: [
                    entity.id.uuidString,
                    entity.type.rawValue,
                    entity.canonicalName,
                    entity.role,
                    entity.notes,
                    iso8601(entity.firstMentionedAt),
                    iso8601(entity.lastMentionedAt),
                    entity.mentionCount,
                    entity.embedding,
                ]
            )
            // Replace aliases atomically.
            try db.execute(
                sql: "DELETE FROM entity_aliases WHERE entity_id = ?",
                arguments: [entity.id.uuidString]
            )
            for alias in entity.aliases {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO entity_aliases (entity_id, alias) VALUES (?, ?)",
                    arguments: [entity.id.uuidString, alias]
                )
            }
        }
        try applyBackupPreference()
    }

    /// Read every entity, in insertion order. Used by EntityStore on
    /// startup to populate the in-memory cache that drives fast
    /// retrieval and fuzzy match.
    func fetchAllEntities() throws -> [Entity] {
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, type, canonical_name, role, notes,
                       first_mentioned_at, last_mentioned_at, mention_count, embedding
                FROM entities
                ORDER BY first_mentioned_at ASC
                """)
            // Collect aliases keyed by entity id, so we don't do N+1 queries.
            let aliasRows = try Row.fetchAll(db,
                sql: "SELECT entity_id, alias FROM entity_aliases")
            var aliasesByEntity: [String: [String]] = [:]
            for row in aliasRows {
                guard let eid = row["entity_id"] as? String,
                      let alias = row["alias"] as? String else { continue }
                aliasesByEntity[eid, default: []].append(alias)
            }
            return rows.compactMap { row in
                entityFromRow(row, aliases: aliasesByEntity[row["id"] as? String ?? ""] ?? [])
            }
        }
    }

    /// Wipe every entity row and every alias. Called from `clearAll`
    /// (Start Fresh) so the memory layer really is fresh.
    func deleteAllEntities() throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM entity_aliases")
            try db.execute(sql: "DELETE FROM entities")
        }
        try applyBackupPreference()
    }

    /// Delete one entity and all its aliases. Called by
    /// `EntityStore.delete(_:)` from the Memory screen's swipe action.
    /// Wrapped in a transaction so the row + aliases are always gone
    /// together, never half-deleted.
    ///
    /// ON DELETE CASCADE on the `entity_aliases.entity_id` FK would
    /// handle aliases automatically, but we only rely on FK enforcement
    /// being enabled (GRDB does enable it by default in recent
    /// versions) — explicit deletion of aliases first is a belt-and-
    /// suspenders guarantee that works regardless.
    ///
    /// No-op if the id doesn't exist. Never throws on missing row.
    func deleteEntity(id: UUID) throws {
        try queue.write { db in
            try db.execute(
                sql: "DELETE FROM entity_aliases WHERE entity_id = ?",
                arguments: [id.uuidString]
            )
            try db.execute(
                sql: "DELETE FROM entities WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
        try applyBackupPreference()
    }

    // MARK: - Destructive

    /// Clears every message, the running summary, and all entity memory.
    /// Used by ConversationStore when the user taps "Start fresh" in the
    /// sidebar. Wrapped in a single transaction so there's no in-between
    /// state where messages are gone but summary/entities remain.
    func clearAll() throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM messages")
            try db.execute(sql: "DELETE FROM summary")
            // ON DELETE CASCADE on entity_aliases means deleting entities
            // cleans their aliases automatically, but we're explicit for
            // clarity.
            try db.execute(sql: "DELETE FROM entity_aliases")
            try db.execute(sql: "DELETE FROM entities")
        }
        try applyBackupPreference()
    }

    func setICloudBackupEnabled(_ enabled: Bool) throws {
        let previousValue = Self.iCloudBackupEnabled
        Self.iCloudBackupEnabled = enabled
        do {
            try applyBackupPreference()
        } catch {
            Self.iCloudBackupEnabled = previousValue
            throw error
        }
    }

    // MARK: - Helpers

    private func applyBackupPreference() throws {
        let shouldExclude = !Self.iCloudBackupEnabled
        for url in managedURLs where FileManager.default.fileExists(atPath: url.path) {
            var values = URLResourceValues()
            values.isExcludedFromBackup = shouldExclude
            var mutableURL = url
            try mutableURL.setResourceValues(values)
        }
    }

    private var managedURLs: [URL] {
        [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
            pendingWritesURL,
        ]
    }

    private func messageFromRow(_ row: Row) -> Message? {
        guard
            let idString = row["id"] as? String,
            let id = UUID(uuidString: idString),
            let roleString = row["role"] as? String,
            let role = Message.Role(rawValue: roleString),
            let text = row["text"] as? String,
            let createdAtString = row["created_at"] as? String,
            let createdAt = parseISO8601(createdAtString)
        else {
            return nil
        }
        // `was_cancelled` is present in rows fetched after v3 migration;
        // absent in any theoretical pre-migration read path. Default false.
        let wasCancelled = (row["was_cancelled"] as? Int) == 1
        return Message(
            id: id,
            role: role,
            text: text,
            wasCancelled: wasCancelled,
            createdAt: createdAt
        )
    }

    private func entityFromRow(_ row: Row, aliases: [String]) -> Entity? {
        guard
            let idString = row["id"] as? String,
            let id = UUID(uuidString: idString),
            let typeString = row["type"] as? String,
            let type = EntityType(rawValue: typeString),
            let canonical = row["canonical_name"] as? String,
            let notes = row["notes"] as? String,
            let firstString = row["first_mentioned_at"] as? String,
            let firstAt = parseISO8601(firstString),
            let lastString = row["last_mentioned_at"] as? String,
            let lastAt = parseISO8601(lastString),
            let count = row["mention_count"] as? Int
        else {
            return nil
        }
        let role = row["role"] as? String
        let embedding = row["embedding"] as? Data
        return Entity(
            id: id,
            type: type,
            canonicalName: canonical,
            role: role,
            notes: notes,
            aliases: aliases,
            firstMentionedAt: firstAt,
            lastMentionedAt: lastAt,
            mentionCount: count,
            embedding: embedding
        )
    }

    private func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter.cached.string(from: date)
    }

    private func parseISO8601(_ string: String) -> Date? {
        ISO8601DateFormatter.cached.date(from: string)
    }
}

private extension ISO8601DateFormatter {
    /// Shared formatter. ISO8601DateFormatter is thread-safe for parsing and
    /// formatting after configuration per Apple's documentation, even though
    /// it doesn't conform to Sendable. nonisolated(unsafe) tells the Swift 6
    /// strict-concurrency checker we've verified this ourselves.
    nonisolated(unsafe) static let cached: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
