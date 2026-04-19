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
final class MessageDatabase {

    let queue: DatabaseQueue

    /// The on-disk location. Inside the app sandbox's Library/ so it's
    /// backed up by iCloud by default (which is fine — the user can delete
    /// the app to wipe the conversation if they want).
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

    init(path: String? = nil) throws {
        let dbPath = path ?? Self.fileURL.path
        self.queue = try DatabaseQueue(path: dbPath)
        try runMigrations()
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

        try migrator.migrate(queue)
    }

    // MARK: - Messages

    /// Append a new message.
    func insert(_ message: Message) throws {
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO messages (id, role, text, created_at, is_summarized)
                VALUES (?, ?, ?, ?, 0)
                """,
                arguments: [
                    message.id.uuidString,
                    message.role.rawValue,
                    message.text,
                    iso8601(message.createdAt)
                ]
            )
        }
    }

    /// Update the text of an existing message (used for streaming AI replies).
    func updateText(id: UUID, text: String) throws {
        try queue.write { db in
            try db.execute(
                sql: "UPDATE messages SET text = ? WHERE id = ?",
                arguments: [text, id.uuidString]
            )
        }
    }

    /// All messages, oldest first. Used once on app launch to populate the
    /// in-memory view model.
    func fetchAllMessages() throws -> [Message] {
        try queue.read { db in
            let rows = try Row.fetchAll(db,
                sql: "SELECT id, role, text, created_at FROM messages ORDER BY created_at ASC"
            )
            return rows.compactMap(messageFromRow)
        }
    }

    /// Un-summarized messages only, oldest first. Used to build the context
    /// window for the LLM (summary + these).
    func fetchUnsummarizedMessages() throws -> [Message] {
        try queue.read { db in
            let rows = try Row.fetchAll(db,
                sql: """
                    SELECT id, role, text, created_at
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
                    SELECT id, role, text, created_at
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
    }

    // MARK: - Helpers

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
        return Message(id: id, role: role, text: text, createdAt: createdAt)
    }

    private func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter.cached.string(from: date)
    }

    private func parseISO8601(_ string: String) -> Date? {
        ISO8601DateFormatter.cached.date(from: string)
    }
}

private extension ISO8601DateFormatter {
    /// Thread-safe shared formatter. ISO8601DateFormatter itself is
    /// thread-safe for reads after configuration.
    static let cached: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
