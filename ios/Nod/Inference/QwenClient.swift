// QwenClient.swift
// Qwen 3 4B (4-bit) via MLX Swift — the alternate listening-loop engine.
//
// Why Qwen? Two reasons:
//   1. AFM is Apple-Intelligence-gated. Many users won't have it enabled or
//      will have regional/device restrictions. Qwen runs on any device with
//      enough RAM (roughly iPhone 15 Pro and up for the 4B).
//   2. Open weights mean we can fine-tune for the listening voice later.
//
// Note: the MLX registry ships Qwen 3 4B (not Qwen 3.5 — that family hasn't
// been converted to an `mlx-community/*` 4-bit build yet). Qwen 3 4B is the
// right starting point; swapping the ModelConfiguration when 3.5 lands is
// a one-line change.
//
// Model weights (~2.3GB) are downloaded on first use via HubApi. EngineHolder
// observes `makeStateStream()` to drive the download progress UI.
//
// Concurrency shape: QwenClient is an actor. The heavy MLX objects
// (LanguageModel, Tokenizer, KV cache) aren't Sendable, so we keep them
// behind MLX's own `ModelContainer` actor and run all generation inside
// `container.perform { context in ... }`. Only Sendable values (String)
// cross the boundary back into our actor.

import Foundation
import Hub
import MLX
import MLXLLM
import MLXLMCommon

actor QwenClient: ListeningEngine {

    /// What the engine is doing right now, for the UI.
    enum State: Equatable, Sendable {
        case notLoaded
        case downloading(fractionCompleted: Double)
        case loading
        case ready
        case failed(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.notLoaded, .notLoaded), (.loading, .loading), (.ready, .ready):
                return true
            case (.downloading(let a), .downloading(let b)):
                return a == b
            case (.failed(let a), .failed(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    private(set) var state: State = .notLoaded

    private let listeningPrompt: String
    private let summaryPrompt: String

    /// Loaded once, reused across calls. Nil until `prepare()` succeeds.
    /// ModelContainer is an actor — safe to hold here.
    private var container: ModelContainer?

    /// An in-flight load. Subsequent `prepare()` callers await this same
    /// task so we never double-download the 2.3GB weights.
    private var loadingTask: Task<Void, Error>?

    /// State change observer. At most one — replaced on each call.
    /// EngineHolder attaches this to drive the download UI.
    private var stateContinuation: AsyncStream<State>.Continuation?

    /// Model config pinned at type-level. Swap for qwen3.5 family when
    /// mlx-community publishes a 4-bit build.
    private static let modelConfig = LLMRegistry.qwen3_4b_4bit

    /// Cap generation length. Listening-mode replies are a paragraph at most;
    /// anything longer is Qwen hallucinating. 500 tokens ~ 350-400 words.
    private static let maxGenerationTokens = 500

    init() throws {
        self.listeningPrompt = try Self.loadPrompt(named: "listening_mode")
        self.summaryPrompt   = try Self.loadPrompt(named: "summary")
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

    // MARK: - State observation

    /// Subscribe to state changes. Yields the current state immediately,
    /// then every subsequent change until the stream is cancelled. Only
    /// one observer at a time — calling this twice replaces the continuation.
    func makeStateStream() -> AsyncStream<State> {
        let (stream, continuation) = AsyncStream.makeStream(of: State.self)
        stateContinuation = continuation
        continuation.yield(state)
        return stream
    }

    /// Single point of state mutation. Keep all updates going through
    /// here so observers never miss a transition.
    private func setState(_ new: State) {
        state = new
        stateContinuation?.yield(new)
    }

    // MARK: - Load lifecycle

    /// Download (if needed) and load the model into memory. Safe to call
    /// repeatedly and from multiple callers — only does work the first time.
    func prepare() async throws {
        if container != nil {
            setState(.ready)
            return
        }
        if let existing = loadingTask {
            try await existing.value
            return
        }

        setState(.loading)
        let task = Task { try await self.performLoad() }
        loadingTask = task

        defer { loadingTask = nil }
        try await task.value
    }

    /// Cancel any in-flight download. URLSession (via HubApi) respects
    /// Task cancellation at its suspension points, so the actual network
    /// transfer stops cooperatively. Resets state to .notLoaded so a
    /// subsequent prepare() starts fresh.
    func cancelLoading() {
        loadingTask?.cancel()
        loadingTask = nil
        container = nil
        setState(.notLoaded)
    }

    private func performLoad() async throws {
        do {
            let loaded = try await loadModelContainer(
                hub: HubApi(),
                configuration: Self.modelConfig,
                progressHandler: { [weak self] progress in
                    guard let self else { return }
                    Task { await self.updateDownloadProgress(progress.fractionCompleted) }
                }
            )
            try Task.checkCancellation()
            self.container = loaded
            setState(.ready)
        } catch is CancellationError {
            // Swift task-level cancellation (e.g. Task.cancel propagated
            // before URLSession started).
            setState(.notLoaded)
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            // URLSession-level cancellation — fires when our loadingTask
            // is cancelled mid-download. NOT a failure; treat as notLoaded.
            setState(.notLoaded)
            throw CancellationError()
        } catch {
            let mapped = Self.mapDownloadError(error)
            setState(.failed(String(describing: mapped)))
            throw mapped
        }
    }

    /// Translate URLError / HubApi errors into typed InferenceError cases
    /// so the UI can show user-friendly copy instead of dumping raw
    /// `NSURLErrorDomain` strings.
    private static func mapDownloadError(_ error: Error) -> Error {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet,
                 .networkConnectionLost,
                 .timedOut,
                 .cannotConnectToHost,
                 .dnsLookupFailed:
                return InferenceError.downloadFailedNoNetwork
            case .cannotWriteToFile, .cannotCreateFile:
                return InferenceError.downloadFailedDiskFull
            default:
                return InferenceError.downloadFailedServer
            }
        }
        return error
    }

    private func updateDownloadProgress(_ fraction: Double) {
        switch state {
        case .loading, .downloading, .notLoaded:
            setState(fraction < 1.0 ? .downloading(fractionCompleted: fraction) : .loading)
        case .ready, .failed:
            break
        }
    }

    // MARK: - InferenceEngine

    func respond(
        to userMessage: String,
        context userContext: String
    ) async throws -> String {
        if container == nil {
            try await prepare()
        }
        guard let container else {
            throw InferenceError.modelNotReady
        }

        let instructions: String
        if userContext.isEmpty {
            instructions = listeningPrompt
        } else {
            instructions = listeningPrompt + "\n\n---\n\n" + userContext
        }

        let raw = try await Self.generate(
            container: container,
            instructions: instructions,
            userPrompt: userMessage
        )
        return stripThinkingBlock(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - ConversationSummarizer

    func summarize(messages: [Message], existingSummary: String) async throws -> String {
        if container == nil {
            try await prepare()
        }
        guard let container else {
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

        let raw = try await Self.generate(
            container: container,
            instructions: instructionInput,
            userPrompt: "Produce the updated summary now."
        )
        return stripThinkingBlock(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Generation

    /// Runs one generation pass inside the ModelContainer's isolation.
    /// Everything non-Sendable (ModelContext, KV cache, MLXArrays) stays
    /// on the container actor; only the resulting String crosses back.
    private static func generate(
        container: ModelContainer,
        instructions: String,
        userPrompt: String
    ) async throws -> String {
        try await container.perform { context in
            let chat: [Chat.Message] = [
                .system(instructions),
                .user(userPrompt),
            ]
            let userInput = UserInput(chat: chat)
            let input = try await context.processor.prepare(input: userInput)

            var parameters = GenerateParameters()
            parameters.maxTokens = Self.maxGenerationTokens
            let result: GenerateResult = try MLXLMCommon.generate(
                input: input,
                parameters: parameters,
                context: context
            ) { (_: [Int]) -> GenerateDisposition in .more }

            Stream.gpu.synchronize()
            return result.output
        }
    }

    // MARK: - Helpers

    /// Qwen 3 emits a `<think>…</think>` block before its user-facing reply
    /// when thinking mode is on. We want the reply only. Drop anything up
    /// to and including the closing tag; if there's no tag, return as-is.
    private func stripThinkingBlock(_ text: String) -> String {
        guard let end = text.range(of: "</think>") else { return text }
        return String(text[end.upperBound...])
    }
}
