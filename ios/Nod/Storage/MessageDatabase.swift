// MessageDatabase.swift
// SQLite persistence for the one continuous conversation with Nod.
//
// Schema:
//   messages        — every user/assistant/nod turn, ever.
//                     is_summarized: aged out of the verbatim window and
//                     covered by a chapter note.
//                     recall_excluded: the user deleted the chapter that
//                     covered it; it stays in the chat but Nod no longer
//                     recalls it.
//   chapters        — write-once notes about each stretch of conversation
//                     (see ConversationMemory). What the Memory screen shows.
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

    /// The user's free-form "Anything else" note from the sidebar.
    /// Lives next to the database (not in UserDefaults, which iOS always
    /// backs up) so the same backup preference covers it.
    static let personalNoteURL: URL = fileURL
        .deletingLastPathComponent()
        .appendingPathComponent("nod-personal-note.txt")

    /// Apply the current backup preference to one file. Needed after
    /// any atomic write, because an atomic write replaces the file and
    /// the replacement doesn't inherit `isExcludedFromBackup`.
    static func applyBackupPreference(to url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = !iCloudBackupEnabled
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }

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

        // v5: flag app-written error notices so they can be kept out of
        // the model's history, summaries, and memory extraction.
        migrator.registerMigration("v5_is_error") { db in
            try db.alter(table: "messages") { t in
                t.add(column: "is_error", .integer).notNull().defaults(to: 0)
            }
        }

        // v6: chapter memory replaces the rolling summary and entity
        // memory (see ConversationMemory). An existing summary becomes the
        // first chapter so nobody loses what Nod knew. Entity tables are
        // dropped rather than left behind: memory the user can no longer
        // see or delete shouldn't sit on disk.
        let v6Now = iso8601(Date())
        migrator.registerMigration("v6_chapters") { db in
            try db.create(table: "chapters") { t in
                t.column("id", .text).primaryKey()
                t.column("text", .text).notNull()
                t.column("created_at", .text).notNull()
                t.column("first_message_at", .text).notNull()
                t.column("last_message_at", .text).notNull()
            }
            try db.alter(table: "messages") { t in
                t.add(column: "recall_excluded", .integer).notNull().defaults(to: 0)
            }
            if let summary = try String.fetchOne(db, sql: "SELECT text FROM summary WHERE id = 1"),
               !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let first = try String.fetchOne(db, sql: "SELECT MIN(created_at) FROM messages WHERE is_summarized = 1") ?? v6Now
                let last = try String.fetchOne(db, sql: "SELECT MAX(created_at) FROM messages WHERE is_summarized = 1") ?? v6Now
                try db.execute(
                    sql: "INSERT INTO chapters (id, text, created_at, first_message_at, last_message_at) VALUES (?, ?, ?, ?, ?)",
                    arguments: [UUID().uuidString, summary, v6Now, first, last]
                )
            }
            try db.drop(table: "summary")
            try db.drop(table: "entity_aliases")
            try db.drop(table: "entities")
        }

        try migrator.migrate(queue)
    }

    // MARK: - Messages

    /// Append a new message.
    func insert(_ message: Message) throws {
        try queue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO messages (id, role, text, created_at, is_summarized, was_cancelled, is_error)
                VALUES (?, ?, ?, ?, 0, ?, ?)
                """,
                arguments: [
                    message.id.uuidString,
                    message.role.rawValue,
                    message.text,
                    iso8601(message.createdAt),
                    message.wasCancelled ? 1 : 0,
                    message.isError ? 1 : 0
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

    /// Mark a message as an app-written error notice (or clear the flag).
    func setError(id: UUID, isError: Bool) throws {
        try queue.write { db in
            try db.execute(
                sql: "UPDATE messages SET is_error = ? WHERE id = ?",
                arguments: [isError ? 1 : 0, id.uuidString]
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
                sql: "SELECT id, role, text, created_at, was_cancelled, is_error FROM messages ORDER BY created_at ASC"
            )
            return rows.compactMap(messageFromRow)
        }
    }

    /// Un-summarized messages only, oldest first: what the model sees
    /// verbatim.
    func fetchUnsummarizedMessages() throws -> [Message] {
        try queue.read { db in
            let rows = try Row.fetchAll(db,
                sql: """
                    SELECT id, role, text, created_at, was_cancelled, is_error
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
                    SELECT id, role, text, created_at, was_cancelled, is_error
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

    /// Write a chapter and mark the messages it covers as aged out of
    /// the verbatim window, in one transaction. `chapter` is nil when the
    /// note came back empty (nothing grounded to say); the messages still
    /// age out.
    func compress(ids: [UUID], into chapter: ConversationMemory.Chapter?) throws {
        guard !ids.isEmpty else { return }
        try queue.write { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
            try db.execute(
                sql: "UPDATE messages SET is_summarized = 1 WHERE id IN (\(placeholders))",
                arguments: StatementArguments(ids.map { $0.uuidString })
            )
            if let chapter {
                try db.execute(
                    sql: "INSERT INTO chapters (id, text, created_at, first_message_at, last_message_at) VALUES (?, ?, ?, ?, ?)",
                    arguments: [
                        chapter.id.uuidString, chapter.text, iso8601(chapter.createdAt),
                        iso8601(chapter.firstMessageAt), iso8601(chapter.lastMessageAt),
                    ]
                )
            }
        }
        try applyBackupPreference()
    }

    // MARK: - Chapters

    func fetchChapters() throws -> [ConversationMemory.Chapter] {
        try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, text, created_at, first_message_at, last_message_at
                FROM chapters ORDER BY created_at ASC
                """).compactMap { row in
                guard let id = (row["id"] as? String).flatMap(UUID.init(uuidString:)),
                      let text = row["text"] as? String,
                      let created = (row["created_at"] as? String).flatMap(parseISO8601),
                      let first = (row["first_message_at"] as? String).flatMap(parseISO8601),
                      let last = (row["last_message_at"] as? String).flatMap(parseISO8601) else { return nil }
                return ConversationMemory.Chapter(id: id, text: text, createdAt: created, firstMessageAt: first, lastMessageAt: last)
            }
        }
    }

    /// Forget a chapter: delete the note and stop recalling the user's
    /// messages from the stretch it covered. The messages stay in the chat.
    func forgetChapter(_ chapter: ConversationMemory.Chapter) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM chapters WHERE id = ?", arguments: [chapter.id.uuidString])
            try db.execute(
                sql: "UPDATE messages SET recall_excluded = 1 WHERE created_at >= ? AND created_at <= ?",
                arguments: [iso8601(chapter.firstMessageAt), iso8601(chapter.lastMessageAt)]
            )
        }
        try applyBackupPreference()
    }

    /// The user's own messages that Nod may recall (see PastMessageRecall).
    func fetchRecallableUserMessages() throws -> [Message] {
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, role, text, created_at, was_cancelled, is_error
                FROM messages
                WHERE role = 'user' AND recall_excluded = 0
                ORDER BY created_at ASC
                """)
            return rows.compactMap(messageFromRow)
        }
    }

    // MARK: - Destructive

    /// Clears every message and every chapter. Used by ConversationStore
    /// when the user taps "Start fresh". One transaction, so there's no
    /// in-between state where messages are gone but memory remains.
    func clearAll() throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM messages")
            try db.execute(sql: "DELETE FROM chapters")
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
            Self.personalNoteURL,
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
        let wasCancelled: Bool = row["was_cancelled"] ?? false
        let isError: Bool = row["is_error"] ?? false
        return Message(
            id: id,
            role: role,
            text: text,
            wasCancelled: wasCancelled,
            isError: isError,
            createdAt: createdAt
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
