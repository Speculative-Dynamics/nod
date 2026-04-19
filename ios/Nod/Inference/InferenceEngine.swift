// InferenceEngine.swift
// Contract every inference backend (AFM, Qwen via MLX, etc.) conforms to.
//
// Takes the user's new message plus a pre-built conversation context string
// (built by ConversationStore — already contains the running summary plus
// recent un-summarized turns). Returns a streaming response.
//
// The context is built once by ConversationStore and handed over as a ready
// string, so the engine doesn't need to understand message roles, history
// compression, or any of that. It just prepends the context to its system
// prompt and responds.

import Foundation

protocol InferenceEngine: Sendable {
    /// Generate a listening-mode response to the user's latest message.
    ///
    /// - Parameters:
    ///   - userMessage: the text the user just sent
    ///   - context: pre-built context string from ConversationStore.
    ///              Includes the running summary (if any) and recent turns.
    ///              May be empty for the very first message.
    /// - Returns: an AsyncStream of response tokens. Consumer runs it from
    ///            a Task (not the main thread).
    func respond(
        to userMessage: String,
        context: String
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
