// FoundationModelsClient.swift
// Apple's on-device LLM via the FoundationModels framework (iOS 18.2+).
//
// Day 1: use this as the primary inference engine. It's free, instant (no
// model download), ANE-accelerated, and works immediately on any Apple
// Intelligence-capable device (iPhone 15 Pro or later with AI enabled).
//
// Day 3-4: Qwen 3.5 4B joins as an alternative engine. Keep both conforming
// to InferenceEngine so we can compare on real transcripts.
//
// NOTE: this file assumes iOS 18.2's FoundationModels API shape. API names
// may shift slightly between beta and GA. Verify against Xcode's
// autocomplete on first compile:
//   import FoundationModels
//   let session = LanguageModelSession(instructions: "...")
//   try await session.respond(to: "...")

import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

actor FoundationModelsClient: InferenceEngine {

    // The listening-mode system prompt is shipped as a resource file so it's
    // easy to iterate without recompiling. See Resources/Prompts/listening_mode.md.
    private let systemPrompt: String

    init() throws {
        guard let url = Bundle.main.url(
                forResource: "listening_mode",
                withExtension: "md",
                subdirectory: "Prompts"
              ),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw InferenceError.modelNotReady
        }
        self.systemPrompt = text
    }

    func respond(
        to userMessage: String,
        context: [Message]
    ) async throws -> AsyncStream<String> {

        #if canImport(FoundationModels)
        // Check AFM availability before calling. Returns early with a clear
        // error if Apple Intelligence isn't enabled or the system model isn't
        // downloaded yet.
        guard SystemLanguageModel.default.availability == .available else {
            throw InferenceError.modelNotReady
        }

        let session = LanguageModelSession(instructions: systemPrompt)

        // Replay prior context as messages so AFM has conversation history.
        for msg in context.dropLast() {
            if msg.role == .user {
                _ = try await session.respond(to: msg.text)
            }
        }

        // Stream the current response.
        let (stream, continuation) = AsyncStream<String>.makeStream()
        Task.detached(priority: .userInitiated) {
            do {
                let response = try await session.respond(to: userMessage)
                // If AFM returns the full string at once, yield it as one chunk.
                // Day 3: upgrade to token-streaming when the API supports it.
                continuation.yield(response.content)
                continuation.finish()
            } catch {
                continuation.finish()
            }
        }
        return stream
        #else
        // Build-time fallback for when FoundationModels isn't available
        // (older SDK, Simulator without AI support, etc.). Returns a clear
        // placeholder response so the app doesn't silently fail.
        let (stream, continuation) = AsyncStream<String>.makeStream()
        continuation.yield("(FoundationModels isn't available on this build.)")
        continuation.finish()
        return stream
        #endif
    }
}
