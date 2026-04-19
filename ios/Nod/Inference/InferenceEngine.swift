// InferenceEngine.swift
// Contract every inference backend (AFM, Qwen via MLX, etc.) conforms to.
//
// Takes the user's new message plus a pre-built conversation context string
// (built by ConversationStore — already contains the running summary plus
// recent un-summarized turns). Returns the full response.
//
// We used to return AsyncStream<String> here, but FoundationModels' respond()
// doesn't actually emit token-by-token — it returns the complete response at
// once. The stream abstraction added complexity (swallowed errors in a
// detached task) without benefit. When Qwen via MLX lands and real streaming
// is available, we can add a separate `respondStreaming` method.

import Foundation

protocol InferenceEngine: Sendable {
    /// Generate a listening-mode response to the user's latest message.
    ///
    /// - Parameters:
    ///   - userMessage: the text the user just sent
    ///   - context: pre-built context string from ConversationStore.
    ///              Includes the running summary (if any) and recent turns.
    ///              May be empty for the very first message.
    /// - Returns: the AI's full response as a string.
    /// - Throws: an InferenceError if the model isn't ready, refused, etc.
    func respond(
        to userMessage: String,
        context: String
    ) async throws -> String
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

/// Convenience bundle for engines that do BOTH listening responses and
/// compression summarization (FoundationModelsClient, QwenClient). Lets
/// ChatView hold a single `any ListeningEngine` instead of two refs.
protocol ListeningEngine: InferenceEngine, ConversationSummarizer {}
