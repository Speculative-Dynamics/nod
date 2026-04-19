// FoundationModelsClient.swift
// Apple's on-device LLM via the FoundationModels framework (iOS 26+).
// Single source of inference for Phase 1: both the listening loop AND
// the summarization pass run through here.
//
// Prompts live in prompts/ at the repo root. Never inline. If either
// prompt file is missing from the bundle, init throws — a missing prompt
// means the build pipeline is broken and that must be visible.

import Foundation
import FoundationModels

actor FoundationModelsClient: ListeningEngine {

    private let listeningPrompt: String
    private let summaryPrompt: String

    init() throws {
        self.listeningPrompt = try Self.loadPrompt(named: "listening_mode")
        self.summaryPrompt   = try Self.loadPrompt(named: "summary")
    }

    private static func loadPrompt(named name: String) throws -> String {
        guard let url = Bundle.main.url(
                forResource: name,
                withExtension: "md",
                subdirectory: "prompts"
              ),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.isEmpty else {
            throw InferenceError.promptNotFound
        }
        return text
    }

    // MARK: - InferenceEngine

    func respond(
        to userMessage: String,
        context: String
    ) async throws -> String {

        guard SystemLanguageModel.default.availability == .available else {
            throw InferenceError.modelNotReady
        }

        // Build instructions: listening-mode prompt + the compressed context
        // from ConversationStore. One inference call per turn — no replay
        // loop, no repeated tokenization of history. Session is throwaway;
        // a fresh one per call because the context is already embedded.
        let instructions: String
        if context.isEmpty {
            instructions = listeningPrompt
        } else {
            instructions = listeningPrompt + "\n\n---\n\n" + context
        }

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: userMessage)
        return response.content
    }

    // MARK: - ConversationSummarizer

    func summarize(messages: [Message], existingSummary: String) async throws -> String {
        guard SystemLanguageModel.default.availability == .available else {
            throw InferenceError.modelNotReady
        }

        let transcript = messages.map { m -> String in
            switch m.role {
            case .user:      return "User: \(m.text)"
            case .assistant: return "Nod: \(m.text)"
            case .nod:       return "(Nod nodded silently.)"
            }
        }.joined(separator: "\n")

        let instructionInput: String
        if existingSummary.isEmpty {
            instructionInput = """
            \(summaryPrompt)

            ---

            EXISTING SUMMARY: (none yet — this is the first compression pass)

            NEW EXCHANGES TO INCORPORATE:
            \(transcript)
            """
        } else {
            instructionInput = """
            \(summaryPrompt)

            ---

            EXISTING SUMMARY:
            \(existingSummary)

            NEW EXCHANGES TO INCORPORATE:
            \(transcript)
            """
        }

        let session = LanguageModelSession(instructions: instructionInput)
        let response = try await session.respond(to: "Produce the updated summary now.")
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
