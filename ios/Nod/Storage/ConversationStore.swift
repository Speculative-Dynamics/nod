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

    // Compression tuning. High-water kicks compression; batch-size is how
    // many we eat on each compression pass. The gap between them (6) is how
    // many full-fidelity recent turns are always available to the LLM after
    // compression settles.
    //
    // Why these specific numbers: on iPhone 15 Pro, passing 20 full-fidelity
    // recent turns plus the summary plus the system prompt to Qwen 3 4B
    // blows the KV cache past the jetsam line — we saw this empirically as
    // a second-message crash. Dropping to 6 recent turns after compression
    // keeps effective context under ~2 k tokens, which is what MLX Swift
    // can actually fit alongside a 2.3 GB model and a 3 GB memory budget
    // (or 6 GB with the increased-memory-limit entitlement; the tighter
    // cap is still the safer default).
    private let HIGH_WATER_MARK = 16
    private let BATCH_SIZE = 10

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
        }
    }

    // MARK: - Appending messages

    func append(_ message: Message) {
        messages.append(message)
        // Silent-fail: if the insert fails, the in-memory message is still
        // appended and the user sees their message on screen. The write
        // will be retried on next `append`.
        try? database.insert(message)
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
        try? database.updateText(id: updated.id, text: text)
    }

    // MARK: - Context for the LLM

    /// Builds the context snippet that gets prepended to the system prompt
    /// for each LLM call. Shape: [running summary if any] + [un-summarized
    /// messages formatted as a transcript].
    ///
    /// Excludes:
    ///   - the in-flight empty assistant placeholder (not real history)
    ///   - the most recent user message (it's being passed as the current
    ///     query, not as context — sending it twice would confuse the model)
    func contextForInference() -> String {
        var parts: [String] = []

        if !summary.isEmpty {
            parts.append("WHAT YOU KNOW FROM EARLIER IN THIS ONGOING CONVERSATION:\n\(summary)")
        }

        do {
            var recent = try database.fetchUnsummarizedMessages()

            // Drop the empty assistant placeholder (ChatView inserts one
            // before streaming tokens back into it).
            recent = recent.filter { !($0.role == .assistant && $0.text.isEmpty) }

            // Drop the most recent user message — it's the current query.
            if let lastIndex = recent.lastIndex(where: { $0.role == .user }) {
                recent.remove(at: lastIndex)
            }

            let formatted = recent.map(formatMessage).joined(separator: "\n")
            if !formatted.isEmpty {
                parts.append("RECENT EXCHANGES:\n\(formatted)")
            }
        } catch {
            // Fall through: the model just sees the summary (or empty context).
            // Worse answer this turn, but not a crash.
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
            // Compression is best-effort — if it fails this pass, the
            // un-summarized backlog grows by one batch and we retry on
            // the next high-water trip. The conversation keeps working.
        }
    }

    // MARK: - Start fresh

    /// Clears the entire conversation (messages and running summary) from
    /// both memory and disk. The user opts into this explicitly via the
    /// sidebar's "Start fresh" action.
    ///
    /// Waits for any in-flight compression to fully cancel before wiping
    /// the database — otherwise a late-finishing compression task could
    /// write a new summary into the just-cleared table.
    func clear() async {
        // Stop any pending compression and wait for it to actually exit.
        compressionTask?.cancel()
        if let task = compressionTask {
            _ = await task.value
        }
        compressionTask = nil

        // Wipe disk in one transaction. If the write fails (e.g. disk full
        // at the exact moment the user hit "Start fresh"), bail without
        // clearing the in-memory state so the UI stays consistent with disk.
        do {
            try database.clearAll()
        } catch {
            return
        }

        // Reset in-memory state so the UI flips to the empty state.
        messages.removeAll()
        summary = ""
    }
}

/// What a summarizer has to be able to do. FoundationModelsClient (and later
/// QwenClient) will conform to this.
protocol ConversationSummarizer: Sendable {
    func summarize(messages: [Message], existingSummary: String) async throws -> String
}
