// ConversationMemory.swift
// Everything Nod remembers beyond the recent turns it sees verbatim:
//
//   - Chapter notes. When older messages age out of the verbatim window,
//     the model writes a short note about that stretch (write-once, never
//     rewritten, so details can't drift), grounded against what the user
//     actually said (see MemoryGrounding). The latest note always goes to
//     the model for continuity; older ones only when relevant. These are
//     what the Memory screen shows, and the user can delete any of them.
//   - The user's own past messages, searched on every send (see
//     PastMessageRecall). This is where specifics come from.
//
// Value type with no storage of its own: ConversationStore loads it from
// the database and keeps it in sync. The eval runner drives the same
// type, so evals exercise exactly this logic.

import Foundation

struct ConversationMemory: Sendable {

    struct Chapter: Identifiable, Equatable, Sendable {
        let id: UUID
        let text: String
        let createdAt: Date
        /// Time span of the messages the note covers.
        let firstMessageAt: Date
        let lastMessageAt: Date
    }

    private(set) var chapters: [Chapter] = []
    private var messageIndex = PastMessageRecall()
    private var chapterIndex = PastMessageRecall()

    init() {}

    // MARK: - Updates

    /// Index a user message for recall. Only the user's own words are
    /// indexed: Nod's replies aren't facts about their life.
    mutating func addUserMessage(id: UUID, text: String, date: Date) {
        messageIndex.add(id: id, text: text, date: date, order: Self.order(date))
    }

    mutating func removeMessages(ids: Set<UUID>) {
        messageIndex.remove(ids: ids)
    }

    mutating func addChapter(_ chapter: Chapter) {
        chapters.append(chapter)
        chapters.sort { $0.createdAt < $1.createdAt }
        chapterIndex.add(id: chapter.id, text: chapter.text, date: chapter.createdAt, order: Self.order(chapter.createdAt))
    }

    /// Forget a chapter: its note, and recall of the user's messages from
    /// the stretch it covered. Returns the forgotten message ids.
    @discardableResult
    mutating func forgetChapter(id: UUID) -> Set<UUID> {
        guard let chapter = chapters.first(where: { $0.id == id }) else { return [] }
        chapters.removeAll { $0.id == id }
        chapterIndex.remove(ids: [id])
        let covered = Set(messageIndex.entries
            .filter { $0.date >= chapter.firstMessageAt && $0.date <= chapter.lastMessageAt }
            .map(\.id))
        messageIndex.remove(ids: covered)
        return covered
    }

    // MARK: - Context

    /// The memory part of the model's context for `userMessage`.
    ///
    /// - Parameter verbatimSince: date of the oldest message the model
    ///   already sees verbatim. Only messages older than that are recalled.
    func context(
        for userMessage: String,
        personalization: String,
        verbatimSince: Date?,
        now: Date = Date()
    ) -> String {
        let latest = chapters.last
        let older = latest.map { latest in
            chapterIndex.recall(for: userMessage, before: Self.order(latest.createdAt), topK: 2)
                .map { "(\(Self.relativeLabel($0.date, now: now))) \($0.text)" }
        } ?? []
        let limit = verbatimSince.map(Self.order) ?? Int.max
        let past = messageIndex.recall(for: userMessage, before: limit)
            .map { "(\(Self.relativeLabel($0.date, now: now))) \"\($0.text)\"" }
        return ListeningTurns.contextBlock(
            personalization: personalization,
            latestChapter: latest?.text ?? "",
            olderChapters: older,
            pastMessages: past
        )
    }

    // MARK: - Chapter writing

    /// Turn a model-written note into a chapter, dropping any sentence
    /// that names something the user didn't say. Nil if nothing grounded
    /// is left.
    static func makeChapter(note: String, covering messages: [Message], now: Date = Date()) -> Chapter? {
        let userText = messages.filter { $0.role == .user }.map(\.text).joined(separator: "\n")
        let grounded = MemoryGrounding.clean(note, source: userText)
        guard !grounded.isEmpty,
              let first = messages.first?.createdAt,
              let last = messages.last?.createdAt else { return nil }
        return Chapter(id: UUID(), text: grounded, createdAt: now, firstMessageAt: first, lastMessageAt: last)
    }

    // MARK: - Helpers

    private static func order(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970 * 1000)
    }

    /// "earlier today", "yesterday", "3 days ago", "2 weeks ago",
    /// "in March", "in March 2025".
    static func relativeLabel(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "earlier today" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days == 1 { return "yesterday" }
        if days < 7 { return "\(days) days ago" }
        if days < 35 {
            let weeks = days / 7
            return weeks == 1 ? "last week" : "\(weeks) weeks ago"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = calendar.isDate(date, equalTo: now, toGranularity: .year) ? "MMMM" : "MMMM yyyy"
        return "in " + formatter.string(from: date)
    }
}
