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
    //
    // iOS flattens resource paths by default, so look for the file at the
    // bundle root first, then fall back to a subdirectory lookup. If the
    // file is missing entirely, fall back to an embedded minimal prompt —
    // the app should never be unusable just because a resource didn't copy.
    private let systemPrompt: String

    init() {
        self.systemPrompt = Self.loadSystemPrompt()
    }

    private static func loadSystemPrompt() -> String {
        // Try flat path first (iOS default behavior)
        if let url = Bundle.main.url(forResource: "listening_mode", withExtension: "md"),
           let text = try? String(contentsOf: url, encoding: .utf8),
           !text.isEmpty {
            return text
        }
        // Try subdirectory (in case the build copies with structure preserved)
        if let url = Bundle.main.url(forResource: "listening_mode", withExtension: "md", subdirectory: "Prompts"),
           let text = try? String(contentsOf: url, encoding: .utf8),
           !text.isEmpty {
            return text
        }
        // Embedded fallback. App still works. Listening-mode prompt file
        // takes precedence when present.
        return embeddedFallbackPrompt
    }

    private static let embeddedFallbackPrompt = """
    You are Nod. You listen.

    Your job is not to solve problems. Your job is to be present — the way a \
    trusted friend is present when someone is venting. You reflect back what \
    you hear briefly, and you sit with uncomfortable feelings without trying \
    to fix them.

    Your responses are short. Usually one or two sentences. Rarely more.

    Do not give advice unless explicitly asked. Do not cheerlead. Do not \
    minimize. Do not perform sympathy with phrases like "that sounds so hard" \
    or "I'm sorry you're going through this." Do not follow up unsolicited.

    Speak like a real person who cares. Not a therapist, not a coach, not an \
    assistant.
    """

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
