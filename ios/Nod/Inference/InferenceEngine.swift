// InferenceEngine.swift
// Protocol that both FoundationModelsClient and QwenClient conform to.
//
// Lets us swap which engine runs the listening loop at runtime (e.g., via
// a feature flag for A/B comparison on real transcripts). Both return a
// streaming AsyncStream<String> so the UI can show tokens as they arrive
// rather than waiting for the full response.

import Foundation

protocol InferenceEngine: Sendable {
    /// Generate a listening-mode response to the user's latest message,
    /// given the prior conversation as context.
    ///
    /// Returns an AsyncStream of tokens. Consumer is expected to call this
    /// from a Task (not the main thread).
    func respond(
        to userMessage: String,
        context: [Message]
    ) async throws -> AsyncStream<String>
}

/// Errors any InferenceEngine may throw. Clients should handle these with
/// user-visible messaging — never silent failures.
enum InferenceError: Error {
    case modelNotReady
    case promptNotFound          // system prompt file missing from bundle (build bug)
    case guardrailViolation      // AFM refused emotional content
    case outOfMemory
    case interrupted             // phone call, app suspension, etc.
}
