// ConversationStore.swift
// The one continuous conversation with Nod. Backed by SQLite via
// MessageDatabase so it survives app close, restart, and reboot.
//
// Per the product thesis: no sessions, no "new chat." One user, one ongoing
// relationship with Nod. This object is the in-memory view of that
// relationship plus the compression machinery that lets it run forever.
//
// Compression ("the magic in the backend"): once the un-summarized message
// count crosses HIGH_WATER_MARK, the oldest BATCH_SIZE messages get rolled
// into the running summary. Everything between that summary and the latest
// message is sent to the LLM as full-fidelity context.

import Foundation
import SwiftUI

@MainActor
final class ConversationStore: ObservableObject {

    @Published private(set) var messages: [Message] = []

    // Compression tuning. High-water kicks compression; low-water is how many
    // we eat on each compression pass. The gap (20) is how many full-fidelity
    // recent turns are always available to the LLM after compression settles.
    private let HIGH_WATER_MARK = 40
    private let BATCH_SIZE = 20

    private let database: MessageDatabase
    private let summarizer: () -> ConversationSummarizer?

    /// The running compressed summary. Mirrors what's in the summary table;
    /// kept in memory so context-building for LLM calls is synchronous.
    private(set) var summary: String = ""

    /// Compression runs on a background task. We hold the handle so we don't
    /// fire a second one while the first is still running.
    private var compressionTask: Task<Void, Never>?

    init(database: MessageDatabase, summarizer: @escaping () -> ConversationSummarizer?) {
        self.database = database
        self.summarizer = summarizer
        loadFromDisk()
    }

    private func loadFromDisk() {
        do {
            messages = try database.fetchAllMessages()
            summary = try database.fetchSummary()
        } catch {
            // DB read failures aren't user-visible — start with an empty
            // in-memory state and let the next write heal it.
            print("ConversationStore: failed to load from disk: \(error)")
        }
    }

    // MARK: - Appending messages

    func append(_ message: Message) {
        messages.append(message)
        do {
            try database.insert(message)
        } catch {
            print("ConversationStore: insert failed: \(error)")
        }
        // Only trigger compression on messages with actual text — skip the
        // empty assistant placeholder that ChatView inserts before streaming
        // tokens in, and skip nod (silent acknowledgment) messages.
        if !message.text.isEmpty {
            maybeTriggerCompression()
        }
    }

    /// Used by streaming AI replies — updates the last assistant message in
    /// place as new tokens arrive. Writes-through to the database at the end.
    func replaceLastAssistantMessage(with text: String) {
        guard let lastIndex = messages.lastIndex(where: { $0.role == .assistant }) else { return }
        let current = messages[lastIndex]
        let updated = Message(id: current.id, role: .assistant, text: text, createdAt: current.createdAt)
        messages[lastIndex] = updated
        do {
            try database.updateText(id: updated.id, text: text)
        } catch {
            print("ConversationStore: updateText failed: \(error)")
        }
    }

    // MARK: - Context for the LLM

    /// Builds the context snippet that gets prepended to the system prompt
    /// for each LLM call. Shape: [running summary if any] + [un-summarized
    /// messages formatted as a transcript].
    ///
    /// Excludes any in-flight (empty) assistant message so the LLM sees only
    /// real history, not its own typing placeholder.
    func contextForInference() -> String {
        var parts: [String] = []

        if !summary.isEmpty {
            parts.append("WHAT YOU KNOW FROM EARLIER IN THIS ONGOING CONVERSATION:\n\(summary)")
        }

        do {
            let recent = try database.fetchUnsummarizedMessages()
            let formatted = recent
                .filter { !($0.role == .assistant && $0.text.isEmpty) }
                .map(formatMessage)
                .joined(separator: "\n")
            if !formatted.isEmpty {
                parts.append("RECENT EXCHANGES:\n\(formatted)")
            }
        } catch {
            print("ConversationStore: fetching recent messages failed: \(error)")
        }

        return parts.joined(separator: "\n\n")
    }

    private func formatMessage(_ m: Message) -> String {
        switch m.role {
        case .user:
            return "User: \(m.text)"
        case .assistant:
            return "You (Nod): \(m.text)"
        case .nod:
            return "(You nodded silently.)"
        }
    }

    // MARK: - Compression

    private func maybeTriggerCompression() {
        guard compressionTask == nil else { return }
        do {
            let count = try database.unsummarizedCount()
            guard count >= HIGH_WATER_MARK else { return }
        } catch {
            return
        }
        guard let summarizer = summarizer() else { return }

        compressionTask = Task.detached(priority: .utility) { [weak self] in
            await self?.runCompression(summarizer: summarizer)
        }
    }

    private func runCompression(summarizer: ConversationSummarizer) async {
        defer {
            Task { @MainActor in self.compressionTask = nil }
        }
        do {
            let oldest = try database.fetchOldestUnsummarized(limit: BATCH_SIZE)
            guard !oldest.isEmpty else { return }

            let existingSummary = try database.fetchSummary()
            let newSummary = try await summarizer.summarize(
                messages: oldest,
                existingSummary: existingSummary
            )

            try database.setSummary(newSummary)
            try database.markSummarized(ids: oldest.map(\.id))

            await MainActor.run {
                self.summary = newSummary
            }
        } catch {
            print("ConversationStore: compression failed: \(error)")
        }
    }
}

/// What a summarizer has to be able to do. FoundationModelsClient (and later
/// QwenClient) will conform to this.
protocol ConversationSummarizer: Sendable {
    func summarize(messages: [Message], existingSummary: String) async throws -> String
}
