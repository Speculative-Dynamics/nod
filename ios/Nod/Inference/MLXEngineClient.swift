// MLXEngineClient.swift
// One on-device MLX engine instance, parameterized by MLXModelSpec.
// Generalized from QwenClient — now backs Qwen 3 Instruct 2507,
// Qwen 3.5 4B, and Gemma 4 E2B Text equally.
//
// Why multiple on-device options:
//   1. AFM is Apple-Intelligence-gated. Many users won't have it enabled
//      or will have regional/device restrictions. MLX-based models run on
//      any device with enough RAM (roughly iPhone 15 Pro and up for 4B).
//   2. Open weights across vendors (Alibaba / Google) let users pick
//      based on voice, release recency, and training data mix.
//
// Each spec carries a stable identifier, display name, R2 base URL, and
// a file manifest with pinned SHA-256s. The client itself is identical
// regardless of which spec it's initialized with.
//
// Model weights (~2.3-3.0 GB) are downloaded on first use from our
// Cloudflare R2 bucket (not Hugging Face — HF's public endpoints
// throttle at any real install count). EngineHolder observes
// `makeStateStream()` to drive the download progress UI. See
// `MLXR2BackgroundSession` for the fetch + verify details.
//
// Concurrency shape: this is an actor. The heavy MLX objects
// (LanguageModel, Tokenizer, KV cache) aren't Sendable, so we keep them
// behind MLX's own `ModelContainer` actor and run all generation inside
// `container.perform { context in ... }`. Only Sendable values (String)
// cross the boundary back into our actor.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import Tokenizers
import os

// No `import Hub` — mlx-swift-lm 3.x decoupled from the Hugging Face Hub
// downloader package. By the time we reach loadModelContainer, the files
// are already sitting on disk in Application Support thanks to
// MLXR2BackgroundSession, so we just hand MLX the URL and let it read
// config.json, tokenizer.json, etc. directly.
//
// `import Tokenizers` + `import MLXHuggingFace` are for the macro
// `#huggingFaceTokenizerLoader()` used in performLoad — that's how 3.x
// bridges its internal Tokenizer protocol to swift-transformers'
// AutoTokenizer.

private let log = Logger(subsystem: "app.usenod.nod", category: "mlx.client")

actor MLXEngineClient: ListeningEngine {

    // MARK: - Spec
    //
    // Injected at init. Everything model-specific (name, R2 URL, file
    // manifest, disk directory) lives here.
    let spec: MLXModelSpec

    /// What the engine is doing right now, for the UI.
    ///
    /// The four "progress-ish" cases all carry `DownloadMetrics` so the UI
    /// can render the same card chrome with different headers and frozen
    /// state: .downloading animates, .waitingForNetwork / .waitingForWifi
    /// show the last known progress with the bar frozen and rate nulled,
    /// .paused waits for a Resume tap.
    enum State: Equatable, Sendable {
        case notLoaded
        case downloading(DownloadMetrics)
        /// No connectivity at all (airplane mode, no Wi-Fi, no cellular).
        /// URLSession's `waitsForConnectivity` puts the request into this
        /// state automatically.
        case waitingForNetwork(DownloadMetrics)
        /// Cellular download is disallowed by the user's preference, and
        /// the current path is cellular. Shows "Waiting for Wi-Fi…" with
        /// a "Use cellular this time" one-shot escape hatch.
        case waitingForWifi(DownloadMetrics)
        /// User tapped Cancel. Resume data persisted to disk; UI offers a
        /// Resume button. Distinct from .notLoaded because there's real
        /// partial progress to preserve in the UI.
        case paused(DownloadMetrics)
        case loading
        case ready
        case failed(String)
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
    // Files are re-hosted at a versioned path on Cloudflare R2 so we can
    // ship future model updates without invalidating existing installs.
    // SHA-256 values are computed once at upload time and pinned in
    // `MLXModelSpec.files` to guarantee bit-identical weights even if the
    // CDN (or our bucket) is ever tampered with.
    //
    // All spec-specific values — URL, files, disk directory, resume data
    // path — come from `self.spec`. Adding a new model is a new
    // `MLXModelSpec` static constant plus an `EnginePreference` case.

    init(spec: MLXModelSpec) throws {
        self.spec = spec
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

    // MARK: - User-facing controls

    /// Pause the active download. The background session persists resume
    /// data to disk and transitions to .paused. A later `prepare()` call
    /// resumes from the same spot. Safe to call if nothing is downloading.
    func cancelDownload() async {
        await MLXR2BackgroundSession.shared.cancelAndPersistResume()
        loadingTask?.cancel()
        loadingTask = nil
    }

    /// Resume a previously paused download. Equivalent to calling
    /// `prepare()` — the session reads persisted resume data on its own.
    func resumeDownload() async throws {
        try await prepare()
    }

    /// One-shot override: allow cellular for THIS run only. Doesn't touch
    /// the persistent preference. The UI exposes this via "Use cellular
    /// this time" on the .waitingForWifi card.
    func useCellularThisTime() async {
        await MLXR2BackgroundSession.shared.useCellularThisTime()
    }

    private func performLoad() async throws {
        do {
            // Phase 1: fetch + verify the weight files from our R2 bucket.
            // `ensureLocalFiles` is a no-op for anything already present
            // and size-valid, so relaunches after a successful download
            // skip straight to phase 2.
            //
            // The background session observes the download events we
            // bridge into `applyDownloadEvent` so both the progress UI
            // and the four waiting/paused states surface through one path.
            let modelDir = spec.modelDirectoryURL

            try await MLXR2BackgroundSession.shared.ensureLocalFiles(
                baseURL: spec.r2BaseURL,
                files: spec.files,
                destinationDir: modelDir,
                resumeDataURL: spec.resumeDataURL,
                on: { [weak self] event in
                    guard let self else { return }
                    Task { await self.applyDownloadEvent(event) }
                }
            )
            try Task.checkCancellation()

            setState(.loading)

            // Phase 2: hand MLX a pre-populated directory. mlx-swift-lm
            // 3.x requires an explicit TokenizerLoader; the
            // `#huggingFaceTokenizerLoader()` macro expands at compile
            // time to an adapter that uses swift-transformers'
            // AutoTokenizer.from(directory:) under the hood. MLX picks
            // up config.json and wires the right architecture via the
            // registered model types.
            let loaded = try await loadModelContainer(
                from: modelDir,
                using: #huggingFaceTokenizerLoader()
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
        } catch DownloadError.canceledByUser {
            // User tapped Cancel. The session already emitted .paused via
            // the event stream, so state is already in .paused(...). Don't
            // overwrite with .failed — this isn't a failure.
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

    /// Called by QwenR2BackgroundSession whenever progress or a
    /// connectivity-state change needs to surface. Metrics carry the full
    /// picture (fraction, bytes, speed, ETA). Transitions from a
    /// progress-ish state map cleanly into one of the four progress
    /// cases; .ready and .failed are terminal so background-task echoes
    /// that arrive after the fact are ignored.
    func applyDownloadEvent(_ event: DownloadEvent) {
        switch state {
        case .ready, .failed:
            return
        default:
            break
        }

        switch event {
        case .progress(let metrics):
            if metrics.fraction >= 1.0 {
                setState(.loading)
            } else {
                setState(.downloading(metrics))
            }
        case .waitingForNetwork(let metrics):
            setState(.waitingForNetwork(metrics.frozen()))
        case .waitingForWifi(let metrics):
            setState(.waitingForWifi(metrics.frozen()))
        case .paused(let metrics):
            setState(.paused(metrics.frozen()))
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
