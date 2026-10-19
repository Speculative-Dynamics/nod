// MLXEngineClient.swift
// One on-device MLX engine instance, parameterized by MLXModelSpec.
// Originally Qwen-only; generalized to back Qwen 3 Instruct 2507,
// Qwen 3.5 4B, and Gemma 4 E2B Text equally via the model spec.
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
import Tokenizers
import os

// Model files are already on disk (MLXR2BackgroundSession) by the time
// we load; generation itself lives in MLXGeneration, shared with evals.

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
    private let chapterPrompt: String

    /// Loaded once, reused across calls. Nil until `prepare()` succeeds.
    /// ModelContainer is an actor — safe to hold here.
    private var container: ModelContainer?

    /// An in-flight load. Subsequent `prepare()` callers await this same
    /// task so we never double-download the 2.3GB weights.
    private var loadingTask: Task<Void, Error>?

    /// State change observer. At most one — replaced on each call.
    /// EngineHolder attaches this to drive the download UI.
    private var stateContinuation: AsyncStream<State>.Continuation?

    /// Ceiling for chapter notes (two to four sentences). Listening
    /// replies pass a per-style `GenerationOptions.maxTokens` instead.
    /// Every saved token is ~100 KB of KV on a 28-layer / 8-KV-head 4B
    /// model, which matters on a 3 GB-budget iPhone 15 Pro.
    private static let maxChapterTokens = 200

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
        self.listeningPrompt  = try Self.loadPrompt(named: "listening_mode")
        self.chapterPrompt    = try Self.loadPrompt(named: "chapter_note")
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

    // Note: The earlier `cancelLoading()` method was removed as dead
    // code. Its only caller (EngineHolder's engine-switch path) now
    // uses `cancelDownload()` so that switching engines mid-download
    // persists resume data to the outgoing spec's per-engine file.
    // For "user hit Start fresh / wipe everything", call
    // `MLXModelSpec.deleteDownloadedFiles()` on the relevant spec
    // directly.

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

    /// Drop the loaded ModelContainer to reclaim its weight memory
    /// (~2.3-3.0 GB depending on spec). Two callers today:
    ///   1. EngineHolder's idle timer — after N minutes of no inference.
    ///   2. LaunchCrashBreaker on the FIRST memory-warning strike — give
    ///      the user a chance to stay on their chosen MLX engine by
    ///      releasing weights instead of immediately falling back to AFM.
    /// The next `respond()` call transparently re-prepares from the
    /// already-downloaded files on disk (no re-download). State flips
    /// to .notLoaded so the UI can reflect the reload.
    ///
    /// Safe to call even if nothing is loaded yet; also cancels an
    /// in-flight load task so we don't race a pending prepare().
    func releaseContainer() {
        loadingTask?.cancel()
        loadingTask = nil
        guard container != nil else { return }
        container = nil
        setState(.notLoaded)
    }

    /// One-shot override: allow cellular for THIS run only. Doesn't touch
    /// the persistent preference. The UI exposes this via "Use cellular
    /// this time" on the .waitingForWifi card.
    func useCellularThisTime() async {
        MLXR2BackgroundSession.shared.useCellularThisTime()
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
            // 3.x requires an explicit TokenizerLoader. We provide a
            // small local bridge to swift-transformers'
            // AutoTokenizer.from(modelFolder:) so we don't need the
            // package's macro-based convenience wrapper. MLX picks up
            // config.json and wires the right architecture via the
            // registered model types.
            // Check free memory first. Loading into too little memory
            // gets the app killed by iOS; failing here gets the user a
            // clear message and a chance to close other apps.
            if let available = Self.availableMemory(), available < spec.peakMemoryBytes {
                let neededGB = String(format: "%.1f", Double(spec.peakMemoryBytes) / 1e9)
                log.error("load: \(available, privacy: .public) bytes free, \(self.spec.peakMemoryBytes, privacy: .public) needed")
                setState(.failed("Not enough free memory right now (this model needs about \(neededGB) GB). Close some apps and try again."))
                throw InferenceError.outOfMemory
            }
            let loaded = try await MLXGeneration.load(from: modelDir)
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
        } catch InferenceError.outOfMemory {
            // State already set with a readable message above.
            throw InferenceError.outOfMemory
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

    /// Called by MLXR2BackgroundSession whenever progress or a
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
        context userContext: String,
        history: [Message],
        options: GenerationOptions
    ) async throws -> String {
        if container == nil {
            try await prepare()
        }
        guard let container else {
            throw InferenceError.modelNotReady
        }

        let instructions = ListeningTurns.systemText(prompt: listeningPrompt, context: userContext)

        // Thinking is turned off in MLXGeneration (enable_thinking=false),
        // and any leftover <think> block is stripped there.
        return try await MLXGeneration.generate(
            container: container,
            instructions: instructions,
            history: history,
            userPrompt: userMessage,
            maxTokens: options.maxTokens,
            sampling: spec.sampling
        )
    }

    /// Real per-token streaming for MLX. Each yielded element is the FULL
    /// accumulated reply so far — callers just assign the snapshot to the
    /// bubble, no delta math.
    ///
    /// CANCELLATION: when the consumer's `AsyncThrowingStream` is torn
    /// down (Task.cancel on the caller), `continuation.onTermination`
    /// fires and cancels the producer Task. The producer's inner
    /// `for try await generation in stream` loop already honors
    /// Task.cancellation at each suspension, so MLX generation exits
    /// within a token or two of cancellation. This is real stop: the GPU
    /// stops generating, not just the UI stops reading.
    nonisolated func streamResponse(
        to userMessage: String,
        context userContext: String,
        history: [Message],
        options: GenerationOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    if await self.container == nil {
                        try await self.prepare()
                    }
                    guard let container = await self.container else {
                        throw InferenceError.modelNotReady
                    }

                    let instructions = ListeningTurns.systemText(
                        prompt: await self.listeningPrompt,
                        context: userContext
                    )

                    try await MLXGeneration.stream(
                        container: container,
                        instructions: instructions,
                        history: history,
                        userPrompt: userMessage,
                        maxTokens: options.maxTokens,
                        sampling: self.spec.sampling
                    ) { snapshot in
                        // Guard against cancellation before each yield.
                        // Throwing CancellationError breaks the MLX loop
                        // cooperatively — the GPU stops generating.
                        try Task.checkCancellation()
                        // Strip `<think>...</think>` progressively. While
                        // the model is still inside a thinking block,
                        // cleaned is empty — typing-dots cover that
                        // window. Once the close tag lands we begin
                        // yielding snapshots of the user-visible reply.
                        let cleaned = MLXGeneration.stripThinkingBlock(snapshot)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !cleaned.isEmpty {
                            continuation.yield(cleaned)
                        }
                    }

                    try Task.checkCancellation()
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                producer.cancel()
            }
        }
    }

    /// Bytes this app can still allocate before iOS terminates it. Nil
    /// where that isn't measurable (Simulator, macOS).
    private static func availableMemory() -> UInt64? {
        #if os(iOS) && !targetEnvironment(simulator)
        return UInt64(os_proc_available_memory())
        #else
        return nil
        #endif
    }

    // MARK: - ChapterWriter

    func chapterNote(messages: [Message]) async throws -> String {
        if container == nil {
            try await prepare()
        }
        guard let container else {
            throw InferenceError.modelNotReady
        }
        return try await MLXGeneration.chapterNote(
            container: container,
            prompt: chapterPrompt,
            messages: messages,
            maxTokens: Self.maxChapterTokens
        )
    }
}
