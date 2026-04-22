// FoundationModelsClient.swift
// Apple's on-device LLM via the FoundationModels framework (iOS 26+).
// Single source of inference for Phase 1: both the listening loop AND
// the summarization pass run through here.
//
// Prompts live in prompts/ at the repo root. Never inline. If either
// prompt file is missing from the bundle, init throws — a missing prompt
// means the build pipeline is broken and that must be visible.
//
// Session strategy (the important architectural choice):
// ──────────────────────────────────────────────────────
// AFM's `LanguageModelSession` has native multi-turn memory — the session
// accumulates user/assistant turns in its own KV cache and remembers them
// across `respond(to:)` calls. We lean on that instead of the older
// "fresh session per call with narrated history in the instructions"
// pattern, which forced the model to re-read the entire conversation as
// system-message narration every turn and made it hard for the model to
// recall anything specific.
//
// Lifecycle:
//   1. On first `respond()` (or after invalidation), seed a new session
//      with instructions = listeningPrompt + context + narrated history.
//      The narrated history is the one-time flat-text backfill so the
//      model knows what happened before this session started — after
//      that it tracks turns natively.
//   2. On subsequent `respond()` calls, reuse the session and just call
//      `session.respond(to: userMessage)`. AFM handles everything.
//   3. Invalidate the session when the seed would differ: personalization
//      changed, summary changed, or the user explicitly started fresh.
//      We fingerprint the seed inputs to detect this.
//   4. `releaseSession()` drops the session — called on engine teardown
//      (idle unload, memory-warning first strike, engine switch) to
//      parallel MLX's `releaseContainer()`.
//
// Known tradeoff: on session invalidation the model loses its native
// chat-turn KV cache and has to rebuild from the narrated seed. That
// means the first turn after a personalization/summary change costs
// more than subsequent turns. Acceptable — invalidations are rare.

import CryptoKit
import Foundation
import FoundationModels

actor FoundationModelsClient: ListeningEngine {

    private let listeningPrompt: String
    private let summaryPrompt: String
    private let extractionPrompt: String

    /// Live session for the listening loop. `nil` before first `respond()`
    /// and after `releaseSession()`. Recreated on next inference.
    private var listeningSession: LanguageModelSession?

    /// Hash of the inputs we used to seed `listeningSession`. If the next
    /// call's seed would differ (personalization updated, summary updated),
    /// invalidate and recreate. Keeping this as a hash (not the raw strings)
    /// keeps memory footprint tiny and comparison O(1).
    private var listeningSessionFingerprint: String?

    init() throws {
        self.listeningPrompt  = try Self.loadPrompt(named: "listening_mode")
        self.summaryPrompt    = try Self.loadPrompt(named: "summary")
        self.extractionPrompt = try Self.loadPrompt(named: "entity_extraction")
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
        context: String,
        history: [Message],
        options: GenerationOptions
    ) async throws -> String {
        // AFM's LanguageModelSession API doesn't expose a max-tokens
        // knob — Apple manages the generation budget internally. Accepted
        // for protocol conformance but intentionally not used here.
        _ = options

        guard SystemLanguageModel.default.availability == .available else {
            throw InferenceError.modelNotReady
        }

        // Seed the session if we don't have one, or invalidate if the
        // seed inputs changed. Fingerprinting on context only — history
        // accumulates naturally within the session, so changes there are
        // expected and do NOT invalidate.
        let fingerprint = Self.fingerprint(for: context)
        if listeningSession == nil || listeningSessionFingerprint != fingerprint {
            let seedInstructions = buildSeedInstructions(
                context: context,
                history: history
            )
            listeningSession = LanguageModelSession(instructions: seedInstructions)
            listeningSessionFingerprint = fingerprint
        }

        guard let session = listeningSession else {
            // Unreachable — we just assigned above. Belt-and-suspenders.
            throw InferenceError.modelNotReady
        }

        let response = try await session.respond(to: userMessage)
        return response.content
    }

    /// Drop the in-memory listening session. Called on engine teardown
    /// (idle unload, memory warning, engine switch). Parallels
    /// `MLXEngineClient.releaseContainer()` so `EngineHolder` can treat
    /// both engines uniformly for memory-reclaim.
    ///
    /// The next `respond()` will transparently create a fresh session
    /// seeded from current context + history.
    func releaseSession() {
        listeningSession = nil
        listeningSessionFingerprint = nil
    }

    /// Tell iOS to preload the Apple FoundationModels weights into
    /// memory BEFORE the user sends their first message. Without this,
    /// the very first `respond()` pays a cold-model-load cost (~1-2s
    /// on iPhone 17 Pro, longer on older AI-capable devices) on top of
    /// the actual inference — which users perceive as "the whole app
    /// is lagging" rather than "the model is loading for the first
    /// time."
    ///
    /// Parallels `MLXEngineClient.prepare()`. EngineHolder fires both
    /// from ChatView's deferred `.task` ~500 ms post-mount, so by the
    /// time the user types and hits send the model is already warm.
    ///
    /// Implementation detail: creates a throwaway `LanguageModelSession`
    /// just to call `prewarm()` on it — that's what signals iOS to
    /// start loading. The session itself gets discarded. The REAL
    /// listening session is built lazily on first `respond()` with the
    /// proper context; since the model is already in memory by then,
    /// session init is fast and the visible latency collapses to just
    /// inference time.
    ///
    /// Safe to call multiple times — `prewarm()` on an already-warm
    /// model is a no-op. Guarded by the usual availability check so we
    /// don't try to warm AFM on an iPhone 15 base (silent no-op).
    func prewarm() {
        guard SystemLanguageModel.default.availability == .available else { return }
        let session = LanguageModelSession(instructions: "")
        session.prewarm()
    }

    /// Build the instructions string used to seed a fresh session. This
    /// is the one place where history gets narrated as flat text — we
    /// need it inside the system message at session creation so AFM
    /// knows what happened before we started tracking turns natively.
    /// After this, new turns get added via `session.respond(to:)` and
    /// AFM handles them as first-class multi-turn context.
    private func buildSeedInstructions(context: String, history: [Message]) -> String {
        var parts: [String] = [listeningPrompt]
        if !context.isEmpty {
            parts.append("---")
            parts.append(context)
        }
        if !history.isEmpty {
            let narrated = history.map { m -> String in
                switch m.role {
                case .user:      return "User: \(m.text)"
                case .assistant: return "You (Nod): \(m.text)"
                case .nod:       return "(You nodded silently.)"
                }
            }.joined(separator: "\n")
            parts.append("RECENT EXCHANGES (before the live session started):\n\(narrated)")
        }
        return parts.joined(separator: "\n\n")
    }

    /// SHA-256 of the seed-determining content. We hash rather than store
    /// the raw string so memory stays small even if the summary grows.
    private static func fingerprint(for context: String) -> String {
        let digest = SHA256.hash(data: Data(context.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
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

        // Summary is intentionally a throwaway session. It's structurally
        // a one-shot task, not a conversation — reusing the listening
        // session would pollute its KV cache with "produce the updated
        // summary now" turns that have nothing to do with the user's
        // actual conversation.
        let session = LanguageModelSession(instructions: instructionInput)
        let response = try await session.respond(to: "Produce the updated summary now.")
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - EntityExtractor

    /// Extract structured entities (people / places / projects / situations)
    /// from a batch of conversation messages. Uses AFM's `@Generable`
    /// support so we get guaranteed-valid JSON without any parsing layer —
    /// this is why AFM is the preferred path for extraction even when the
    /// user is on an MLX listening engine. See EntityExtractorService for
    /// the routing that prefers AFM regardless of the user's chat preference.
    ///
    /// The session is a throwaway like summarize() — extraction is
    /// structurally a one-shot task. Reusing the listening session would
    /// pollute its KV cache with extraction-specific prompts.
    ///
    /// Throws `LanguageModelSession.GenerationError.guardrailViolation`
    /// when AFM refuses the emotional content; the caller falls back to
    /// the MLX path in that case.
    func extractEntities(from messages: [Message]) async throws -> ExtractedEntities {
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

        let instructionInput = """
        \(extractionPrompt)

        ---

        CONVERSATION CHUNK TO ANALYZE:
        \(transcript)
        """

        let session = LanguageModelSession(instructions: instructionInput)
        // The @Generable overload of respond(generating:) makes AFM return
        // a structured ExtractedEntities value directly. No JSON parsing,
        // no regex, no hope-and-pray.
        let response = try await session.respond(
            to: "Return the list of entities now.",
            generating: ExtractedEntities.self
        )
        return response.content
    }
}
