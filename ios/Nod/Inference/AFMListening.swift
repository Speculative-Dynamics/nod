// AFMListening.swift
// One listening turn on Apple's on-device model. Shared by
// FoundationModelsClient and the eval runner (ios/evals/runner).
//
// Each turn builds a fresh LanguageModelSession from a Transcript:
// instructions, then prior turns as real prompt/response entries, then
// the new prompt. Nothing carries over between turns. That keeps the
// model's view identical to what's on disk (regenerate, Start fresh and
// error filtering just work), sends history as real chat turns instead
// of narrated text, and lets us budget the context window every turn.

import Foundation
import FoundationModels

enum AFMListening {

    /// Fallback when the runtime can't report the context window.
    private static let defaultContextSize = 4096

    /// Sampling temperature for listening replies. Evals showed the
    /// default letting long conversations fall into loops (the same
    /// question shape reply after reply); 1.0 keeps replies varied.
    static let listeningTemperature: Double = 1.0

    /// Headroom for chat-template overhead our estimate doesn't see.
    private static let templateMarginTokens = 128

    static var contextSize: Int {
        if #available(iOS 26.4, macOS 26.4, *) {
            return SystemLanguageModel.default.contextSize
        }
        return defaultContextSize
    }

    /// Stream one reply as cumulative snapshots.
    ///
    /// Retries once on a context overflow before any text has arrived
    /// (with the older half of the history dropped), and once on a refusal
    /// (at the default temperature — evals saw the guardrail trip on
    /// harmless messages, sometimes mid-reply). A refusal that persists
    /// surfaces as `InferenceError.guardrailViolation`.
    static func streamReply(
        prompt systemPrompt: String,
        context: String,
        history: [Message],
        userMessage: String,
        maxTokens: Int,
        temperature: Double? = listeningTemperature
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                let system = ListeningTurns.systemText(prompt: systemPrompt, context: context)
                let assembled = ListeningTurns.assemble(history: history, userMessage: userMessage)
                let budget = contextSize - maxTokens - templateMarginTokens
                var turns = ListeningTurns.fit(
                    turns: assembled.turns,
                    systemText: system,
                    prompt: assembled.prompt,
                    budgetTokens: budget
                )
                var attempt = 0
                var temperature = temperature
                while true {
                    attempt += 1
                    var yieldedAny = false
                    do {
                        let session = makeSession(system: system, turns: turns)
                        let stream = session.streamResponse(
                            to: assembled.prompt,
                            options: FoundationModels.GenerationOptions(
                                temperature: temperature,
                                maximumResponseTokens: maxTokens
                            )
                        )
                        for try await snapshot in stream {
                            try Task.checkCancellation()
                            yieldedAny = true
                            continuation.yield(snapshot.content)
                        }
                        continuation.finish()
                        return
                    } catch is CancellationError {
                        continuation.finish(throwing: CancellationError())
                        return
                    } catch {
                        switch classify(error) {
                        case .contextOverflow where attempt == 1 && !yieldedAny && !turns.isEmpty:
                            turns = Array(turns.suffix(turns.count / 2))
                            while turns.first?.speaker == .nod { turns.removeFirst() }
                            continue
                        case .refusal where attempt == 1:
                            // Also after partial text: snapshots are whole
                            // replies, so the retry's first snapshot simply
                            // replaces what was shown.
                            temperature = nil
                            continue
                        case .refusal:
                            continuation.finish(throwing: InferenceError.guardrailViolation)
                        default:
                            continuation.finish(throwing: error)
                        }
                        return
                    }
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    static func makeSession(system: String, turns: [ListeningTurns.Turn]) -> LanguageModelSession {
        var entries: [Transcript.Entry] = [
            .instructions(Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: system))],
                toolDefinitions: []
            ))
        ]
        for turn in turns {
            let segments: [Transcript.Segment] = [.text(Transcript.TextSegment(content: turn.text))]
            switch turn.speaker {
            case .user:
                entries.append(.prompt(Transcript.Prompt(segments: segments)))
            case .nod:
                entries.append(.response(Transcript.Response(assetIDs: [], segments: segments)))
            }
        }
        return LanguageModelSession(transcript: Transcript(entries: entries))
    }

    enum ErrorKind { case contextOverflow, refusal, other }

    /// Map AFM errors across SDKs: iOS 27 throws `LanguageModelError`;
    /// iOS 26 throws `LanguageModelSession.GenerationError`.
    static func classify(_ error: Error) -> ErrorKind {
        if #available(iOS 27.0, macOS 27.0, *), let error = error as? LanguageModelError {
            switch error {
            case .contextSizeExceeded: return .contextOverflow
            case .guardrailViolation, .refusal: return .refusal
            default: return .other
            }
        }
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: return .contextOverflow
            case .guardrailViolation, .refusal: return .refusal
            default: return .other
            }
        }
        return .other
    }
}
