// ListeningTurns.swift
// Engine-neutral assembly of what the listening model sees each turn:
// one system text (prompt + context) and a clean, alternating list of
// prior turns. Shared by every engine AND by the eval runner in
// ios/evals/runner, so evals exercise the exact assembly the app ships.
//
// Foundation-only on purpose — keep it that way so the runner can
// compile it on macOS without the rest of the app.

import Foundation

enum ListeningTurns {

    struct Turn: Equatable, Sendable {
        enum Speaker: Equatable, Sendable { case user, nod }
        let speaker: Speaker
        let text: String
    }

    /// What a `.nod` row (silent acknowledgement) looks like to the model.
    static let nodMarker = "(Nod nodded silently.)"

    /// The per-turn context block, in order:
    ///   - personalization (frames everything else)
    ///   - the latest chapter note, for continuity
    ///   - older chapter notes relevant to the current message
    ///   - the user's own past messages relevant to the current message
    /// Empty parts are omitted. Everything past personalization is
    /// labelled "don't bring it up unless they do" — memory is for when
    /// they raise something, never for volunteering.
    static func contextBlock(
        personalization: String,
        latestChapter: String,
        olderChapters: [String],
        pastMessages: [String]
    ) -> String {
        var parts: [String] = []
        if !personalization.isEmpty {
            parts.append(personalization)
        }
        if !latestChapter.isEmpty {
            parts.append("WHAT'S BEEN HAPPENING LATELY (from earlier in this conversation; don't bring it up unless they do):\n\(latestChapter)")
        }
        if !olderChapters.isEmpty {
            let lines = olderChapters.map { "- \($0)" }.joined(separator: "\n")
            parts.append("FROM FURTHER BACK, RELATED TO WHAT THEY JUST SAID:\n\(lines)")
        }
        if !pastMessages.isEmpty {
            let lines = pastMessages.map { "- \($0)" }.joined(separator: "\n")
            parts.append("THINGS THEY TOLD YOU BEFORE, IN THEIR WORDS (newest first; use only if it's what they're talking about now):\n\(lines)")
        }
        return parts.joined(separator: "\n\n")
    }

    /// The system message: listening prompt, then the per-turn context
    /// block (personalization, summary, relevant memories) if any.
    static func systemText(prompt: String, context: String) -> String {
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return prompt }
        return prompt + "\n\n---\n\n" + trimmed
    }

    /// Turn stored history into the turns the model should see, plus the
    /// final user prompt.
    ///
    /// - Drops empty rows and app-written error notices.
    /// - Merges consecutive same-speaker rows. A user message whose reply
    ///   failed would otherwise sit next to the next user message, and
    ///   chat templates expect turns to alternate.
    /// - Drops leading Nod turns so the conversation opens with the user.
    /// - If history ends on an unanswered user turn, folds it into the
    ///   current prompt instead of sending two user turns in a row.
    static func assemble(history: [Message], userMessage: String) -> (turns: [Turn], prompt: String) {
        var turns: [Turn] = []
        for message in history where !message.isError {
            let speaker: Turn.Speaker
            let text: String
            switch message.role {
            case .user:
                speaker = .user
                text = message.text
            case .assistant:
                speaker = .nod
                text = message.text
            case .nod:
                speaker = .nod
                text = nodMarker
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let last = turns.last, last.speaker == speaker {
                turns[turns.count - 1] = Turn(speaker: speaker, text: last.text + "\n\n" + trimmed)
            } else {
                turns.append(Turn(speaker: speaker, text: trimmed))
            }
        }
        while turns.first?.speaker == .nod { turns.removeFirst() }

        var prompt = userMessage
        if let last = turns.last, last.speaker == .user {
            prompt = last.text + "\n\n" + userMessage
            turns.removeLast()
        }
        return (turns, prompt)
    }

    /// Drop the oldest turns (in user+Nod pairs) until the estimated size
    /// fits `budgetTokens`. The system text and prompt are never trimmed.
    static func fit(
        turns: [Turn],
        systemText: String,
        prompt: String,
        budgetTokens: Int
    ) -> [Turn] {
        var kept = turns
        let fixed = estimatedTokens(systemText) + estimatedTokens(prompt)
        while !kept.isEmpty,
              fixed + kept.reduce(0, { $0 + estimatedTokens($1.text) + 4 }) > budgetTokens {
            kept.removeFirst()
            if kept.first?.speaker == .nod { kept.removeFirst() }
        }
        return kept
    }

    /// Conservative token estimate (~3 characters per token for English
    /// prose; real tokenizers average closer to 4). Overestimating only
    /// costs a little history; underestimating overflows the context.
    static func estimatedTokens(_ text: String) -> Int {
        (text.count + 2) / 3
    }
}
