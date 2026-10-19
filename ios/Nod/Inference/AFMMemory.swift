// AFMMemory.swift
// Memory writing on Apple's on-device model: a short note about each
// stretch of conversation as it ages out of the verbatim window. Shared
// by FoundationModelsClient and the eval runner (ios/evals/runner). A
// one-shot session — a task, not conversation — so it never touches the
// listening context.

import Foundation
import FoundationModels

enum AFMMemory {

    /// Messages as a plain transcript for the memory prompts. Error
    /// notices are not conversation and are left out.
    static func transcript(_ messages: [Message]) -> String {
        messages
            .filter { !$0.isError }
            .map { m -> String in
                switch m.role {
                case .user:      return "User: \(m.text)"
                case .assistant: return "Nod: \(m.text)"
                case .nod:       return ListeningTurns.nodMarker
                }
            }
            .joined(separator: "\n")
    }

    /// A short, write-once note about one batch of exchanges (see
    /// prompts/chapter_note.md). Unlike `summarize`, it never rewrites
    /// earlier notes, so details can't drift across passes.
    static func chapterNote(prompt: String, messages: [Message]) async throws -> String {
        let instructions = """
        \(prompt)

        ---

        EXCHANGES:
        \(transcript(messages))
        """
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: "Write the note now.",
            options: FoundationModels.GenerationOptions(temperature: 0.3)
        )
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
