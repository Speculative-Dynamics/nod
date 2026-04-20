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
// Model weights (~2 GB) are downloaded on first use from our Cloudflare R2
// bucket (not Hugging Face — HF's public endpoints throttle at any real
// install count). EngineHolder observes `makeStateStream()` to drive the
// download progress UI. See QwenR2Downloader for the fetch + verify details.
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
import os

private let log = Logger(subsystem: "app.usenod.nod", category: "qwen.client")

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

    /// Cap generation length. Listening-mode replies are a paragraph at most;
    /// anything longer is Qwen hallucinating. 250 tokens ~ 175-200 words —
    /// plenty for a warm 2-3 sentence reflection, and the shorter ceiling
    /// keeps KV cache growth bounded during generation (every extra token
    /// is ~100 KB of cache on a 28-layer, 8-KV-head model).
    private static let maxGenerationTokens = 250

    // MARK: - R2 download source
    //
    // Files are re-hosted at a versioned path so we can ship future model
    // updates without invalidating existing installs. SHA-256 values are
    // computed once at upload time and pinned here to guarantee bit-
    // identical weights even if the CDN (or our bucket) is ever tampered
    // with.
    //
    // As of build 18 we're on Qwen 3 4B **Instruct 2507** (July 2025 Alibaba
    // refresh). Key differences from the original Qwen 3 4B we shipped first:
    //   - Instruct-only build: no "thinking mode" in the chat template, so
    //     responses don't begin with `<think>...</think>` reasoning blocks.
    //     We no longer need the `/no_think` prompt prefix; the defensive
    //     `stripThinkingBlock` helper stays as a safety net in case Qwen
    //     ever slips one through anyway.
    //   - ~3 months newer training data.
    //   - Ships a separate `chat_template.jinja` that swift-transformers'
    //     tokenizer loads automatically from the model directory.
    //   - Includes `generation_config.json` for default sampling params.
    private static let r2BaseURL = URL(
        string: "https://pub-6cf269f2cf044828b0b016d58295da25.r2.dev/qwen3-4b-instruct-2507/v1"
    )!

    private static let r2Files: [QwenR2Downloader.FileSpec] = [
        .init(name: "config.json",
              sha256: "574349e5a343236546fda55e4744a76e181f534182d7dc60ff1bad7e7a502849",
              size: 938),
        .init(name: "merges.txt",
              sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5",
              size: 1_671_853),
        .init(name: "model.safetensors",
              sha256: "2a73c6c248601ab904e035548abd8e6abb65ea27dcb5f342fb0a8910eb44173f",
              size: 2_263_022_417),
        .init(name: "model.safetensors.index.json",
              sha256: "388d811b8b7c2608dd04cce1bcb04a8bf715d19b42790894e6d3427ff429a777",
              size: 63_964),
        .init(name: "tokenizer.json",
              sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4",
              size: 11_422_654),
        .init(name: "tokenizer_config.json",
              sha256: "4397cc477eb6d79715ccd2000accd6b3531928f30029665832fa1b255f24d2b9",
              size: 5_440),
        .init(name: "vocab.json",
              sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910",
              size: 2_776_833),
        // Special-token maps. Missing these makes swift-transformers' tokenizer
        // fopen-fail on `special_tokens_map.json` and under-register Qwen's
        // ChatML tokens.
        .init(name: "added_tokens.json",
              sha256: "c0284b582e14987fbd3d5a2cb2bd139084371ed9acbae488829a1c900833c680",
              size: 707),
        .init(name: "special_tokens_map.json",
              sha256: "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd",
              size: 613),
        // New in 2507: chat template is split out of tokenizer_config.json
        // into its own jinja file; swift-transformers' tokenizer picks this
        // up automatically from the model directory.
        .init(name: "chat_template.jinja",
              sha256: "40c21f34cf67d8c760ef72f8ad3ae5afad514299d4b06e91dd9a8d705af7b541",
              size: 4_040),
        .init(name: "generation_config.json",
              sha256: "835fffe355c9438e7a25be099b3fccaa98350b83451f9fd2d99512e74f1ade48",
              size: 238),
    ]

    /// Where the verified model files live after a successful download.
    /// Application Support keeps them invisible to Files, out of iCloud
    /// backups, and not evictable like Caches. MLX loads directly from
    /// here via `loadModelContainer(hub:directory:)`.
    private static func modelDirectoryURL() -> URL {
        URL.applicationSupportDirectory
            .appending(path: "Nod")
            .appending(path: "Qwen3-4B-4bit")
    }

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
            // Phase 1: fetch + verify the weight files from our R2 bucket.
            // `ensureLocalFiles` is a no-op for anything already present
            // and size-valid, so relaunches after a successful download
            // skip straight to phase 2.
            let modelDir = Self.modelDirectoryURL()

            try await QwenR2Downloader.ensureLocalFiles(
                baseURL: Self.r2BaseURL,
                files: Self.r2Files,
                destinationDir: modelDir,
                progress: { [weak self] fraction in
                    guard let self else { return }
                    Task { await self.updateDownloadProgress(fraction) }
                }
            )
            try Task.checkCancellation()

            setState(.loading)

            // Phase 2: hand MLX a pre-populated directory. Offline mode
            // stops HubApi from phoning home to Hugging Face for anything
            // that might appear missing.
            let loaded = try await loadModelContainer(
                hub: HubApi(useOfflineMode: true),
                directory: modelDir
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
            log.error("performLoad: failed \(String(describing: mapped), privacy: .public)")
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

        // Qwen 3 Instruct 2507 is an Instruct-only build with no thinking
        // mode baked into the chat template, so we send the user message
        // directly. The `stripThinkingBlock` post-processing stays as a
        // defensive net in case a future model ships with thinking
        // re-enabled.
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

    /// Belt-and-suspenders strip of Qwen's `<think>…</think>` block, even
    /// if `/no_think` wasn't honored and we end up with one anyway.
    ///
    /// Three cases handled:
    ///   • matched `<think>…</think>` → keep what's after the close
    ///   • orphan `<think>` with no close (budget ran out mid-think, the
    ///     exact failure mode we observed) → drop the whole buffer rather
    ///     than leak raw reasoning to the user
    ///   • no `<think>` at all → pass through untouched
    private func stripThinkingBlock(_ text: String) -> String {
        if let end = text.range(of: "</think>") {
            return String(text[end.upperBound...])
        }
        if text.contains("<think>") {
            // Everything after an unclosed `<think>` is internal reasoning
            // we don't want to show. Show only what came before it (usually
            // nothing, since thinking starts the buffer).
            if let start = text.range(of: "<think>") {
                return String(text[..<start.lowerBound])
            }
            return ""
        }
        return text
    }
}
