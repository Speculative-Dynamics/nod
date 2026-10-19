// FoundationModelsClient.swift
// Apple's on-device LLM via the FoundationModels framework (iOS 26+).
// Handles both the listening loop and chapter notes.
//
// Prompts live in prompts/ at the repo root. Never inline. If a
// prompt file is missing from the bundle, init throws — a missing prompt
// means the build pipeline is broken and that must be visible.
//
// Listening turns go through AFMListening, which builds a fresh session
// per turn from the stored history (real prompt/response entries, budgeted
// to the context window) and streams the reply. See AFMListening.swift.

import Foundation
import FoundationModels

actor FoundationModelsClient: ListeningEngine {

    private let listeningPrompt: String
    private let chapterPrompt: String

    init() throws {
        self.listeningPrompt  = try Self.loadPrompt(named: "listening_mode")
        self.chapterPrompt    = try Self.loadPrompt(named: "chapter_note")
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

    /// Streams snapshots of the reply. Cancelling the consumer cancels
    /// the AFM generation (see AFMListening.streamReply).
    nonisolated func streamResponse(
        to userMessage: String,
        context: String,
        history: [Message],
        options: GenerationOptions
    ) -> AsyncThrowingStream<String, Error> {
        guard SystemLanguageModel.default.availability == .available else {
            return AsyncThrowingStream { $0.finish(throwing: InferenceError.modelNotReady) }
        }
        return AFMListening.streamReply(
            prompt: listeningPrompt,
            context: context,
            history: history,
            userMessage: userMessage,
            maxTokens: options.maxTokens
        )
    }

    /// Tell iOS to preload the on-device model (and the listening prompt
    /// prefix) before the first send, so the first reply doesn't pay the
    /// 1-2 s cold-load cost. Safe to call repeatedly.
    func prewarm() {
        guard SystemLanguageModel.default.availability == .available else { return }
        let session = LanguageModelSession(instructions: listeningPrompt)
        session.prewarm()
    }

    // MARK: - ChapterWriter

    func chapterNote(messages: [Message]) async throws -> String {
        guard SystemLanguageModel.default.availability == .available else {
            throw InferenceError.modelNotReady
        }
        return try await AFMMemory.chapterNote(prompt: chapterPrompt, messages: messages)
    }
}
