// QwenClient.swift
// Qwen 3.5 4B via MLX Swift — the listening-loop model from day 3-4 onward.
//
// This is a STUB. Day 1-2 uses FoundationModelsClient; day 3 is when you
// integrate mlx-swift-lm via Swift Package Manager, set up Background
// Assets for the ~2.5GB model download, and fill in this class.
//
// Kept as a stub so the InferenceEngine protocol is exercised from day 1.

import Foundation

actor QwenClient: InferenceEngine {

    enum State {
        case notLoaded
        case loading
        case ready
        case error(Error)
    }

    private var state: State = .notLoaded

    init() {
        // Day 3: wire this up with:
        //   import MLX
        //   import MLXLLM
        //   let model = try await ModelLoader.load(...)
    }

    func respond(
        to userMessage: String,
        context: String
    ) async throws -> AsyncStream<String> {
        // Day 3: replace with real MLX inference. Until then, throw so the
        // stub can never silently fall through to production.
        throw InferenceError.modelNotReady
    }
}
