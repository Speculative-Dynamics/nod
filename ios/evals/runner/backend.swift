// backend.swift — which model the runner talks to.
//
//   --engine afm              Apple's on-device model (default)
//   --engine mlx:/path/model  a local folder of MLX model files
//
// MLX support is compiled only in the Swift package build (run.sh picks
// it automatically for mlx engines); the plain swiftc build is AFM-only.

import Foundation
import FoundationModels
#if canImport(MLXLMCommon)
import MLX
import MLXLMCommon
#endif

var engineSpec = "afm"
var mlxModelPath: String? {
    engineSpec.hasPrefix("mlx:") ? String(engineSpec.dropFirst(4)) : nil
}

/// Human-readable description for report headers.
var backendDescription = "Apple on-device"

#if canImport(MLXLMCommon)
nonisolated(unsafe) var mlxContainer: ModelContainer?
nonisolated(unsafe) var mlxSampling: MLXSampling = .qwen3
nonisolated(unsafe) var mlxLoadSeconds: Double = 0
#endif

/// Load the selected backend. Exits with a message if it can't.
@MainActor
func prepareBackend() async {
    if let path = mlxModelPath {
        #if canImport(MLXLMCommon)
        Memory.cacheLimit = 20 * 1024 * 1024  // same as the app
        let dir = URL(fileURLWithPath: path)
        let start = Date()
        do {
            mlxContainer = try await MLXGeneration.load(from: dir)
        } catch {
            print("Couldn't load MLX model at \(path): \(error)")
            exit(1)
        }
        mlxLoadSeconds = Date().timeIntervalSince(start)
        let type = MLXGeneration.modelType(in: dir)
        mlxSampling = MLXSampling.recommended(forModelType: type)
        if let prefillSpec { MLXGeneration.prefillStepSize = prefillSpec }
        backendDescription = "MLX \(dir.lastPathComponent) (\(type), loaded in \(String(format: "%.1f", mlxLoadSeconds)) s\(prefillSpec.map { ", prefill \($0)" } ?? ""))"
        #else
        print("This build has no MLX support. Use run.sh, which builds the MLX runner for mlx engines.")
        exit(1)
        #endif
    } else {
        guard case .available = SystemLanguageModel.default.availability else {
            print("Apple's on-device model isn't available: \(SystemLanguageModel.default.availability)")
            print("Check System Settings → Apple Intelligence & Siri.")
            exit(1)
        }
        backendDescription = "Apple on-device (context \(AFMListening.contextSize) tokens)"
    }
}

/// Peak memory used by the model so far, if measurable (MLX only).
func backendPeakMemoryGB() -> Double? {
    #if canImport(MLXLMCommon)
    if mlxContainer != nil { return Double(Memory.peakMemory) / 1e9 }
    #endif
    return nil
}

/// One streamed reply, as the app's active engine would produce it.
func replyStream(
    prompt: String,
    context: String,
    history: [Message],
    userMessage: String,
    maxTokens: Int,
    temperature: Double?,
    samplingMode: GenerationOptions.SamplingMode?
) -> AsyncThrowingStream<String, Error> {
    #if canImport(MLXLMCommon)
    if let container = mlxContainer {
        let sampling = mlxSampling
        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    try await MLXGeneration.stream(
                        container: container,
                        instructions: ListeningTurns.systemText(prompt: prompt, context: context),
                        history: history,
                        userPrompt: userMessage,
                        maxTokens: maxTokens,
                        sampling: sampling
                    ) { snapshot in
                        try Task.checkCancellation()
                        let cleaned = MLXGeneration.stripThinkingBlock(snapshot)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !cleaned.isEmpty { continuation.yield(cleaned) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }
    #endif
    return AFMListening.streamReply(
        prompt: prompt, context: context, history: history,
        userMessage: userMessage, maxTokens: maxTokens,
        temperature: temperature, samplingMode: samplingMode
    )
}

/// A chapter note, written by the same engine (as in the app).
func writeChapterNote(prompt: String, messages: [Message]) async throws -> String {
    #if canImport(MLXLMCommon)
    if let container = mlxContainer {
        return try await MLXGeneration.chapterNote(container: container, prompt: prompt, messages: messages)
    }
    #endif
    return try await AFMMemory.chapterNote(prompt: prompt, messages: messages)
}
