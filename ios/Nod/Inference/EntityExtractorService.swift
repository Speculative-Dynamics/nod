// EntityExtractorService.swift
// Routes entity extraction to the best available engine: AFM first
// (structured output via @Generable, ANE-accelerated, zero extra model
// weights in our process), and the user's active listening engine
// (Qwen / Gemma) as fallback when AFM refuses on emotional content or
// is unavailable on the device.
//
// Why the routing lives here and not inside ConversationStore:
//   - Keeps `ConversationStore` focused on conversation mechanics and
//     entity storage, not LLM-engine selection.
//   - Lets us hold a DEDICATED FoundationModelsClient instance just for
//     extraction, independent of which engine the user picked for the
//     listening loop. Means an MLX user still gets AFM's high-quality
//     structured extraction automatically.
//   - Isolates the guardrail-fallback logic in one place.
//
// Failure mode contract: extraction is best-effort. If both primary
// and fallback fail (both throw), we return an empty ExtractedEntities
// rather than propagating. The conversation keeps working; the user
// just doesn't get new memory from this batch. Next compression pass
// retries.

import Foundation
import FoundationModels
import os

private let log = Logger(subsystem: "app.usenod.nod", category: "entity.extractor")

@MainActor
final class EntityExtractorService {

    /// Dedicated AFM instance for extraction. Independent of the user's
    /// engine preference — even if they chat through Qwen, extraction
    /// still prefers AFM for the structured-output benefit.
    ///
    /// Nil when AFM prompts couldn't load (should never happen on a
    /// correctly-built app) or when the device can't host AFM. The
    /// fallback path handles both cases.
    private let primary: FoundationModelsClient?

    /// Closure that returns the user's current listening engine. We use
    /// a closure rather than a direct reference because `EngineHolder`
    /// swaps engines on preference change; reading through the closure
    /// guarantees we always see the current one.
    private let fallbackProvider: () -> (any ListeningEngine)?

    init(fallbackProvider: @escaping () -> (any ListeningEngine)?) {
        // Lazy init — if AFM prompts fail to load (dev-time bundle issue),
        // we silently fall through to the MLX path. Production builds ship
        // the prompts, so this should always succeed at runtime.
        self.primary = try? FoundationModelsClient()
        self.fallbackProvider = fallbackProvider
    }

    /// Run extraction on a batch of messages. Tries AFM first, falls back
    /// to the active engine, returns empty on total failure. Never throws.
    func extract(from messages: [Message]) async -> ExtractedEntities {
        log.info("extract: starting with \(messages.count, privacy: .public) messages (primary=\(self.primary != nil, privacy: .public))")
        if let primary {
            do {
                let result = try await primary.extractEntities(from: messages)
                log.info("extract: AFM returned \(result.items.count, privacy: .public) items — \(result.items.map(\.name).joined(separator: ", "), privacy: .public)")
                return result
            } catch let error as LanguageModelSession.GenerationError {
                // AFM refused (guardrailViolation is the common one) or hit
                // some other generation error. Fall through to the MLX path.
                log.info("AFM extraction refused: \(String(describing: error), privacy: .public); falling back")
            } catch InferenceError.modelNotReady {
                // AFM isn't available on this device or this session.
                // Don't log — this is expected on non-AFM devices.
            } catch {
                log.warning("AFM extraction failed: \(String(describing: error), privacy: .public); falling back")
            }
        }

        // Fallback: use the user's active listening engine. Works for both
        // Qwen/Gemma paths — they share the MLXEngineClient JSON prompt
        // implementation. If the active engine is ALSO AFM (and primary
        // somehow failed above), we just try AFM a second time through
        // a different instance — still costs nothing.
        guard let fallback = fallbackProvider() else {
            log.info("No fallback engine available; extraction returns empty")
            return ExtractedEntities(items: [])
        }
        do {
            let result = try await fallback.extractEntities(from: messages)
            log.info("extract: fallback returned \(result.items.count, privacy: .public) items — \(result.items.map(\.name).joined(separator: ", "), privacy: .public)")
            return result
        } catch {
            log.warning("Fallback extraction failed: \(String(describing: error), privacy: .public); returning empty")
            return ExtractedEntities(items: [])
        }
    }
}
