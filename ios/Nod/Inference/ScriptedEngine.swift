// ScriptedEngine.swift
// A stand-in listening engine for end-to-end tests (debug builds only),
// chosen with the launch argument `-nodFakeEngine <mode>`. The Simulator
// can't run Apple's model or the MLX models, so without this nothing past
// "send" could be tested there.
//
// It goes through exactly the same app paths as a real engine (history,
// memory context, personalization, streaming, cancellation, chapter
// notes); only the text generation is scripted. Each reply carries
// plain markers the UI tests read back:
//
//   Heard: <your message>. Remembered: <recalled past message>.
//   About you: <Anything else text>. (history N, limit M)
//
// Modes:
//   on        stream a reply word by word (~40 ms per word)
//   slow      the same, ~300 ms per word after a 3 s pause (Stop, pill)
//   fail      every reply fails
//   failFirst the first reply fails, later ones succeed (Try again)

#if DEBUG
import Foundation

actor ScriptedEngine: ListeningEngine {

    enum Mode: String {
        case on, slow, fail, failFirst
    }

    struct ScriptedFailure: Error {}

    private let mode: Mode
    private var replies = 0

    init(mode: Mode) {
        self.mode = mode
    }

    private func shouldFail() -> Bool {
        replies += 1
        switch mode {
        case .fail: return true
        case .failFirst: return replies == 1
        case .on, .slow: return false
        }
    }

    nonisolated func streamResponse(
        to userMessage: String,
        context: String,
        history: [Message],
        options: GenerationOptions
    ) -> AsyncThrowingStream<String, Error> {
        let text = Self.reply(to: userMessage, context: context, history: history, options: options)
        let delay: Duration = mode == .slow ? .milliseconds(300) : .milliseconds(40)
        return AsyncThrowingStream { continuation in
            let task = Task {
                if await self.shouldFail() {
                    try? await Task.sleep(for: .milliseconds(200))
                    continuation.finish(throwing: ScriptedFailure())
                    return
                }
                // Slow mode also pauses before the first word, so a test
                // can scroll away before the reply starts arriving.
                if self.mode == .slow { try? await Task.sleep(for: .milliseconds(3000)) }
                var snapshot = ""
                for word in text.split(separator: " ") {
                    if Task.isCancelled { break }
                    try? await Task.sleep(for: delay)
                    snapshot += (snapshot.isEmpty ? "" : " ") + word
                    continuation.yield(snapshot)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A chapter note made only of the user's own words, so grounding
    /// keeps it.
    func chapterNote(messages: [Message]) async throws -> String {
        let said = messages.filter { $0.role == .user }.map(\.text)
        guard let first = said.first else { return "" }
        return "They said: \(first)."
    }

    // MARK: - Reply text

    static func reply(to message: String, context: String, history: [Message], options: GenerationOptions) -> String {
        var parts = ["Heard: \(message)."]
        if let recalled = firstRecalled(in: context) {
            parts.append("Remembered: \(recalled).")
        }
        if let aboutYou = section(after: "WHAT THIS PERSON HAS TOLD YOU ABOUT THEMSELVES:", in: context) {
            parts.append("About you: \(aboutYou).")
        }
        parts.append("(history \(history.count), limit \(options.maxTokens))")
        return parts.joined(separator: " ")
    }

    /// The first quoted past message under the recall header.
    private static func firstRecalled(in context: String) -> String? {
        guard let header = context.range(of: "THINGS THEY TOLD YOU BEFORE") else { return nil }
        let after = context[header.upperBound...]
        guard let open = after.range(of: ") \""),
              let close = after[open.upperBound...].firstIndex(of: "\"") else { return nil }
        return String(after[open.upperBound..<close])
    }

    /// The first line after a header, if present.
    private static func section(after header: String, in context: String) -> String? {
        guard let range = context.range(of: header) else { return nil }
        let line = context[range.upperBound...]
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return (line?.isEmpty ?? true) ? nil : line
    }
}
#endif
