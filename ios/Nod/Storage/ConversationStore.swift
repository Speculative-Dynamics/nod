// ConversationStore.swift
// In-memory conversation for day 1. GRDB-backed persistence lands in day 4-5.
//
// When GRDB is added, this class keeps the same API — it just reads/writes
// to a SQLite file instead of an array. Keep the public surface minimal so
// the swap is invisible to ChatView.

import Foundation
import SwiftUI

@MainActor
final class ConversationStore: ObservableObject {
    @Published private(set) var messages: [Message] = []

    func append(_ message: Message) {
        messages.append(message)
        // TODO day 4-5: persist to SQLite via GRDB.
    }

    func replaceLastAssistantMessage(with text: String) {
        // Streaming: replace the in-progress AI message's text as tokens arrive.
        guard let lastIndex = messages.lastIndex(where: { $0.role == .assistant }) else { return }
        let current = messages[lastIndex]
        messages[lastIndex] = Message(id: current.id, role: .assistant, text: text, createdAt: current.createdAt)
    }

    /// Rolling window for model context. Keep last N turns verbatim; older
    /// turns will be summarized once we have structured memory (Phase 2).
    var contextWindow: [Message] {
        Array(messages.suffix(20))
    }
}
