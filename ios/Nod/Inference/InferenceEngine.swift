// InferenceEngine.swift
// Contract every inference backend (AFM, Qwen via MLX, etc.) conforms to.
//
// Three-part input shape per call:
//   - `userMessage`: what the user just sent (final user turn of the chat).
//   - `context`: personalization + running summary, as a string. Goes
//      into the system message.
//   - `history`: un-summarized prior turns as actual `Message` values.
//      Engines pass these as real chat turns so the model's multi-turn
//      attention engages properly. NOT narrated into `context`.
//
// Why split context from history: chat-tuned models (Qwen 3/3.5, Gemma 4,
// AFM) are trained on multi-turn chat-template structure. Embedding
// history as narration inside the system message ("User: X / You: Y")
// leaves the model's multi-turn attention unengaged — verified failure
// mode on Qwen 3.5 4B. The split exists to fix that.
//
// We used to return AsyncStream<String> here, but FoundationModels'
// respond() doesn't actually emit token-by-token — it returns the
// complete response at once. The stream abstraction added complexity
// (swallowed errors in a detached task) without benefit. When real
// streaming is needed we can add a separate `respondStreaming` method.

import Foundation

/// Per-call generation knobs. Extracted so we can expand (sampling,
/// temperature, stop tokens) without another protocol migration.
///
/// Today the only field is `maxTokens`, which varies by the user's
/// response-style preference: brief replies don't need 400 tokens of
/// KV cache headroom, and every token saved is ~100 KB of KV on a
/// 4B / 28-layer / 8-KV-head model. On a 3 GB-budget iPhone 15 Pro,
/// cutting the common case from 400 → 300 shaves ~10 MB off peak
/// resident memory per generation without touching response quality.
struct GenerationOptions: Sendable {
    /// Upper bound on generated tokens. The generator may stop earlier
    /// on EOS or stop-token match; this is just the ceiling.
    var maxTokens: Int

    /// The widest defaults any caller should use today. Summary
    /// compression targets ~300 words ≈ 400 tokens; reply generation
    /// varies by response-style (see `forResponseStyle`).
    static let `default` = GenerationOptions(maxTokens: 400)

    /// Sized for the three user-visible response styles. Callers that
    /// know the style should prefer this over `.default` so we don't
    /// allocate more KV than the style actually produces.
    static func forResponseStyle(_ style: ResponseStyle) -> GenerationOptions {
        switch style {
        case .brief:          return GenerationOptions(maxTokens: 200)
        case .conversational: return GenerationOptions(maxTokens: 300)
        case .deeper:         return GenerationOptions(maxTokens: 400)
        }
    }
}

protocol InferenceEngine: Sendable {
    /// Generate a listening-mode response to the user's latest message.
    ///
    /// History is passed as an ordered list of prior `Message` turns, NOT
    /// narrated inside `context`. This matters because chat-tuned models
    /// (Qwen, Gemma, AFM) are trained on multi-turn chat-template structure
    /// — their attention instincts engage on real turn boundaries, not on
    /// a system-message paragraph that reads "User said X, assistant said
    /// Y." Without this split, 4B-class models routinely fail to recall
    /// prior conversation content (verified symptom on Qwen 3.5 4B in
    /// this app). See `ConversationStore.buildInferenceInputs()` for the
    /// construction of both inputs.
    ///
    /// - Parameters:
    ///   - userMessage: the text the user just sent (becomes the final
    ///     user turn of the chat)
    ///   - context: personalization + running summary, as a string. Goes
    ///     into the system message. Does NOT contain recent exchanges;
    ///     those arrive via `history`.
    ///   - history: un-summarized prior turns in chronological order, with
    ///     the empty assistant placeholder and the current user message
    ///     already filtered out. Empty on the first message of a
    ///     conversation.
    ///   - options: per-call generation knobs (max tokens, etc.).
    /// - Returns: the AI's full response as a string.
    /// - Throws: an InferenceError if the model isn't ready, refused, etc.
    func respond(
        to userMessage: String,
        context: String,
        history: [Message],
        options: GenerationOptions
    ) async throws -> String

    /// Streaming variant of `respond(to:...)`. Yields the FULL accumulated
    /// reply each time (snapshot semantics, not deltas) — the final yield
    /// equals the complete reply. Callers just assign each snapshot to
    /// the bubble; no delta-math required.
    ///
    /// Why snapshots, not deltas: AFM's streaming API yields cumulative
    /// snapshots natively, and diffing them by suffix-length is brittle
    /// (the producer may revise earlier text under some conditions). For
    /// MLX, the implementation accumulates and yields the running string
    /// per token, which is equivalent work.
    ///
    /// CANCELLATION CONTRACT: implementations MUST wire
    /// `AsyncThrowingStream.Continuation.onTermination` to cancel the
    /// underlying generation task. Cancellation of the consumer alone
    /// does NOT free the GPU — the producer must be cancelled explicitly.
    /// Without this, stop buttons become theatrical (UI stops reading
    /// while compute keeps running).
    ///
    /// Conforming engines without native streaming may yield the final
    /// string once and finish — the caller behavior is identical.
    func streamResponse(
        to userMessage: String,
        context: String,
        history: [Message],
        options: GenerationOptions
    ) -> AsyncThrowingStream<String, Error>
}

extension InferenceEngine {
    /// Default atomic `respond` for engines that implement `streamResponse`.
    /// Collects to the LAST yielded snapshot. Rethrows stream errors and
    /// honors `Task.isCancelled` — summarize/extract paths must fail
    /// loudly on model errors, not silently return partial strings.
    ///
    /// Engines that have a cheaper native atomic path (AFM's single-shot
    /// `respond(to:)`) can still override this method to skip the stream
    /// setup overhead.
    func respond(
        to userMessage: String,
        context: String,
        history: [Message],
        options: GenerationOptions
    ) async throws -> String {
        var last = ""
        for try await snapshot in streamResponse(
            to: userMessage,
            context: context,
            history: history,
            options: options
        ) {
            try Task.checkCancellation()
            last = snapshot
        }
        return last
    }
}

/// Errors any InferenceEngine may throw. Clients should handle these with
/// user-visible messaging — never silent failures.
enum InferenceError: Error {
    case modelNotReady
    case promptNotFound          // system prompt file missing from bundle (build bug)
    case guardrailViolation      // AFM refused emotional content
    case outOfMemory
    case interrupted             // phone call, app suspension, etc.
    // MLX-model download failures. Mapped from URLError in MLXEngineClient
    // so ChatView / the readiness bar can show typed copy.
    case downloadFailedNoNetwork
    case downloadFailedDiskFull
    case downloadFailedServer
}

/// Contract for the entity-extraction pass. Runs on a batch of
/// conversation messages and returns a structured list of people,
/// places, projects, and ongoing situations the user mentioned.
///
/// AFM is the strongly preferred implementation — its `@Generable`
/// macro gives us guaranteed-valid JSON with no parsing layer. MLX
/// engines implement this via an extractive JSON prompt + manual
/// parsing, which is the fallback path when AFM refuses (guardrail)
/// or is unavailable. See `EntityExtractorService` for the routing
/// logic that prefers AFM and falls back.
protocol EntityExtractor: Sendable {
    func extractEntities(from messages: [Message]) async throws -> ExtractedEntities
}

/// Convenience bundle for engines that do BOTH listening responses,
/// compression summarization, AND entity extraction. Lets ChatView
/// hold a single `any ListeningEngine` instead of three refs.
protocol ListeningEngine: InferenceEngine, ConversationSummarizer, EntityExtractor {}
