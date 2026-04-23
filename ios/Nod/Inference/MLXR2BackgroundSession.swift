// MLXR2BackgroundSession.swift
// The actual machinery behind on-device MLX model delivery.
// Generalized from the original Qwen-specific class to support an
// arbitrary MLX model via MLXModelSpec — now used for Qwen 3, Qwen 3.5,
// and Gemma 4 E2B.
//
// ==========================================================================
// Why this exists
// ==========================================================================
// Downloading a 2.3 GB model on iOS has three hard requirements that the
// async URLSession convenience API doesn't satisfy:
//
//   1. Reliable progress reporting. `session.download(from:delegate:)` sits
//      on top of the legacy convenience API and silently suppresses some
//      delegate callbacks, which is why users saw the progress bar jump
//      from 0% to 100% without animating. (See Apple Forums 723015.)
//   2. Survives screen lock and app suspension. A foreground URLSession
//      dies when iOS suspends the app; for a 5-10 minute transfer that's
//      a real problem. Background sessions run in nsurlsessiond, outside
//      our process, and keep going.
//   3. Task reattachment on cold launch. If the user kills the app mid-
//      download, iOS keeps downloading. On the next launch we re-create
//      the background URLSession with the same identifier and iOS replays
//      the in-flight delegate events so we can pick up where we left off.
//
// ==========================================================================
// Architecture shape
// ==========================================================================
//
//   ┌────────────────────────────────────────────────────────────┐
//   │  MLXEngineClient (actor)                                         │
//   │    .prepare() / .cancelDownload() / .resumeDownload()       │
//   └──────────┬─────────────────────────────────▲────────────────┘
//              │ calls                            │ applyDownloadEvent()
//              ▼                                  │
//   ┌────────────────────────────────────────────────────────────┐
//   │  MLXR2BackgroundSession (final class, Sendable)            │
//   │    - Singleton via `shared`                                 │
//   │    - Owns one URLSession(configuration: .background(...))   │
//   │    - Holds per-task download progress + rolling speed       │
//   │    - Persists/restores resume data to/from Application Sup- │
//   │      port so Cancel → Resume works across app launches      │
//   │    - Observes NWPathMonitor for cellular detection          │
//   └──────────┬─────────────────────────────────▲────────────────┘
//              │ background delegate callbacks    │ events via closure
//              ▼                                  │
//   ┌────────────────────────────────────────────────────────────┐
//   │  URLSession in nsurlsessiond                                │
//   │  (survives app suspend/kill; reattaches via identifier)     │
//   └────────────────────────────────────────────────────────────┘
//
// ==========================================================================
// Concurrency model
// ==========================================================================
// NSObject because URLSessionDownloadDelegate requires it. `@unchecked
// Sendable` is honest — we guard every mutable bit behind an NSLock.
// Actor would be cleaner but URLSession will not accept an actor as
// delegate and forcing a bridge object costs more than the lock here.
//
// ==========================================================================
// The single-fire continuation dance
// ==========================================================================
// When bridging `downloadTask` → async via `CheckedContinuation`, BOTH
// `didFinishDownloadingTo` (success) and `didCompleteWithError`  (cleanup,
// error=nil on success) can fire back-to-back. Naively resuming in both
// crashes (double-resume is a fatal error). We guard each per-task
// continuation behind an in-struct single-fire flag.
//
// Also: `didFinishDownloadingTo` hands us a temp URL that iOS DELETES when
// the callback returns. We MUST move/copy synchronously inside that
// callback, not after awaiting the caller's continuation. That's why the
// destination path is captured per-task inside `TaskState` rather than
// computed in the async caller.

import CryptoKit
import Foundation
import Network
import os

private let log = Logger(subsystem: "app.usenod.nod", category: "mlx.download")

/// One file to fetch, with integrity metadata.
struct FileSpec: Sendable, Hashable {
    let name: String
    let sha256: String
    let size: Int64
}

enum DownloadError: Error, CustomStringConvertible, Sendable {
    case hashMismatch(file: String)
    case httpError(file: String, status: Int)
    case missingResponse(file: String)
    case exhaustedRetries(file: String, underlying: String)
    case canceledByUser
    case cellularDisallowed

    var description: String {
        switch self {
        case .hashMismatch(let f):            return "SHA-256 mismatch for \(f)"
        case .httpError(let f, let s):        return "HTTP \(s) fetching \(f)"
        case .missingResponse(let f):         return "No HTTP response for \(f)"
        case .exhaustedRetries(let f, let u): return "Exhausted retries for \(f): \(u)"
        case .canceledByUser:                 return "Download canceled by user"
        case .cellularDisallowed:             return "Download paused: Wi-Fi required"
        }
    }
}

final class MLXR2BackgroundSession: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    // MARK: - Singleton

    /// The one instance. Must be touched from `AppDelegate.application(
    /// _:handleEventsForBackgroundURLSession:completionHandler:)` so the
    /// URLSession exists and can replay delegate events on cold relaunch.
    static let shared = MLXR2BackgroundSession()

    // MARK: - Preference keys

    private static let cellularAllowedKey = "Download.cellularAllowed"

    // MARK: - Public preference accessors

    /// User's persistent preference for cellular downloads. Default false
    /// — Wi-Fi only — to respect data plans. User can flip in the sidebar.
    var cellularAllowed: Bool {
        get { UserDefaults.standard.bool(forKey: Self.cellularAllowedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.cellularAllowedKey) }
    }

    // MARK: - Internal state (NSLock-guarded)

    private let lock = NSLock()

    /// Per-running-task state. Keyed by `URLSessionTask.taskIdentifier` so
    /// we can route delegate callbacks back to the right continuation.
    private var taskStates: [Int: TaskState] = [:]

    /// FileSpecs the current run is operating on. Used to look up size /
    /// expected hash from a taskIdentifier and to compute rolled-up
    /// progress across files.
    private var currentManifest: [FileSpec] = []

    /// Bytes already completed from FILES that finished earlier in this
    /// run (excluding the current in-flight task). Used for total progress.
    private var completedByteBase: Int64 = 0

    /// Total bytes across the full manifest (not just to-download). Used
    /// for the denominator in overall progress metrics.
    private var totalManifestBytes: Int64 = 0

    /// UI event sink. Set by the caller (MLXEngineClient). Invoked from a
    /// background queue; the caller is responsible for hopping to main if
    /// it needs to.
    private var onEvent: (@Sendable (DownloadEvent) -> Void)?

    /// When the user hits Cancel, we call `cancel(byProducingResumeData:)`
    /// which is asynchronous. Until the data arrives we're in limbo; the
    /// flag signals "don't treat the incoming error as a retryable fail."
    private var pendingCancelForTask: Set<Int> = []

    /// The iOS-supplied completion handler delivered via
    /// application(_:handleEventsForBackgroundURLSession:...). We must
    /// call it exactly once after urlSessionDidFinishEvents fires, or iOS
    /// marks the session "stuck" and may terminate future downloads.
    private var backgroundCompletionHandler: (() -> Void)?

    /// NWPathMonitor for detecting cellular/Wi-Fi transitions. Drives the
    /// .waitingForWifi event when the user has cellular disallowed and
    /// the device is currently on a cellular path.
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "app.usenod.nod.pathmonitor")
    private var latestPath: NWPath?

    // MARK: - URLSession

    /// Foreground URLSession. We DO NOT use a background (`.background(
    /// withIdentifier:)`) session: iOS aggressively batches `didWriteData`
    /// delivery for background sessions (likely every 15-30 s for a 2 GB
    /// transfer) to conserve battery. That makes the progress bar look
    /// frozen even while bytes are flowing, which was the exact symptom
    /// that drove this refactor.
    ///
    /// The trade-off: foreground sessions die when iOS suspends the app
    /// (screen lock, user switches away for >30 s). We mitigate with
    /// `isIdleTimerDisabled` in ChatView while the card is .downloading,
    /// which keeps the screen awake for the 5-10 min transfer. Resume
    /// data on mid-stream drop still works via `cancel(byProducing-
    /// ResumeData:)`, so a user-initiated cancel is recoverable.
    ///
    /// Keeping `waitsForConnectivity` means the session silently pauses
    /// when there's no network and auto-resumes when it returns. The
    /// delegate's `taskIsWaitingForConnectivity` fires in that window so
    /// we can show "Waiting for the network…" to the user.
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.allowsCellularAccess = true
        config.timeoutIntervalForRequest = DownloadTuning.timeoutIntervalForRequest
        config.timeoutIntervalForResource = DownloadTuning.timeoutIntervalForResource
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    // MARK: - Init / path monitoring

    private override init() {
        super.init()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path)
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    private func handlePathUpdate(_ path: NWPath) {
        let (wasWifiGated, isGatedNow, snapshot) = lock.withLock { () -> (Bool, Bool, DownloadMetrics) in
            latestPath = path
            let was = wifiGatedSnapshot
            let now = isWifiGated(path: path)
            wifiGatedSnapshot = now
            return (was, now, snapshotMetricsLocked())
        }

        // If we were waiting on Wi-Fi and a new Wi-Fi path arrived, emit
        // a progress event so the UI transitions out of "Waiting for
        // Wi-Fi…". If we just transitioned INTO the gate, announce it.
        if wasWifiGated && !isGatedNow {
            onEvent?(.progress(snapshot))
        } else if !wasWifiGated && isGatedNow {
            onEvent?(.waitingForWifi(snapshot))
        }
    }

    /// Current cached "are we gated on Wi-Fi" state, updated on each path
    /// transition so we don't recompute in hot paths. Must be accessed
    /// under lock.
    private var wifiGatedSnapshot: Bool = false

    /// Compute whether the current path gates us. Must be called under lock.
    private func isWifiGated(path: NWPath?) -> Bool {
        guard let path else { return false }
        if cellularAllowed { return false }
        return path.usesInterfaceType(.cellular)
    }

    // MARK: - Resume data disk persistence
    //
    // Resume data is SCOPED TO THE MODEL, not the session. When the user
    // pauses Qwen 3.5 at 45% and switches to Gemma 4, Qwen 3.5's resume
    // blob stays put at `<modelDir>/.resume.data` — Gemma 4 has its own.
    // A shared app-global filename would silently overwrite, losing
    // progress on any model the user isn't currently on. The active run's
    // resume URL is stored in `currentResumeURL` below and updated at the
    // top of each `ensureLocalFiles` call.
    //
    // Every read/write goes through the three helpers below so there's
    // only one place to audit.

    /// The resume-data URL for the currently-active download run.
    /// Lock-protected; set at the top of `ensureLocalFiles`, read by the
    /// retry loop and cancellation path.
    private var currentResumeURL: URL?

    private func persistResumeData(_ data: Data) {
        let url = lock.withLock { currentResumeURL }
        guard let url else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
        try? excludeFromBackup(url.deletingLastPathComponent())
    }

    private func loadPersistedResumeData() -> Data? {
        guard let url = lock.withLock({ currentResumeURL }) else { return nil }
        return try? Data(contentsOf: url)
    }

    private func clearPersistedResumeData() {
        guard let url = lock.withLock({ currentResumeURL }) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Background URL session completion handler

    /// Invoked by `AppDelegate.application(_:handleEvents..., completion:)`.
    /// We store the completion, trigger session creation (which starts
    /// delegate callback replay), and call the completion from
    /// `urlSessionDidFinishEvents`. Failure to call the handler means
    /// iOS marks our session as misbehaving.
    func handleBackgroundEvents(completionHandler: @escaping () -> Void) {
        lock.withLock {
            backgroundCompletionHandler = completionHandler
        }
        // Touching `session` triggers lazy construction and iOS begins
        // replaying the delegate events immediately.
        _ = self.session
    }

    // MARK: - Public API: start / cancel / resume

    /// Ensure every file in `files` is present and verified under
    /// `destinationDir`. Returns when all files are in place or throws on
    /// terminal failure. Emits DownloadEvent updates via `on`.
    ///
    /// `resumeDataURL` is the per-engine path where cancellation will
    /// persist the URLSession resume blob. Pass the spec's
    /// `resumeDataURL` — it's `<modelDir>/.resume.data`. Scoping here
    /// means switching engines mid-download doesn't clobber the outgoing
    /// model's resume progress.
    ///
    /// Safe to call from MLXEngineClient (an actor) — every mutation is
    /// NSLock-guarded.
    func ensureLocalFiles(
        baseURL: URL,
        files: [FileSpec],
        destinationDir: URL,
        resumeDataURL: URL,
        on event: @escaping @Sendable (DownloadEvent) -> Void
    ) async throws {
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        try excludeFromBackup(destinationDir)

        // Plan: identify which files need downloading. Size-match anything
        // already present (trusted because we only move to final dest
        // after hash verify).
        var toDownload: [FileSpec] = []
        var completedBytes: Int64 = 0
        for f in files {
            let path = destinationDir.appending(path: f.name)
            if FileManager.default.fileExists(atPath: path.path) {
                let actualSize = (try? FileManager.default
                    .attributesOfItem(atPath: path.path)[.size] as? Int64) ?? -1
                if actualSize == f.size {
                    completedBytes += f.size
                    continue
                }
                try? FileManager.default.removeItem(at: path)
            }
            toDownload.append(f)
        }

        let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }

        // Initialize shared state for this run.
        lock.withLock {
            self.currentManifest = files
            self.completedByteBase = completedBytes
            self.totalManifestBytes = totalBytes
            self.onEvent = event
            self.currentResumeURL = resumeDataURL
            self.wifiGatedSnapshot = isWifiGated(path: latestPath)
        }

        // Short-circuit: everything already on disk.
        if toDownload.isEmpty {
            event(.progress(DownloadMetrics(
                fraction: 1.0,
                bytesWritten: totalBytes,
                totalBytes: totalBytes,
                bytesPerSecond: 0,
                secondsRemaining: nil
            )))
            return
        }

        // Largest-first: the 2.26 GB safetensors dominates byte-wise, so
        // starting with it makes the progress bar meaningful from the
        // first second. Tokenizers finish in <5 s each and barely move
        // the needle.
        let sorted = toDownload.sorted { $0.size > $1.size }

        // Emit an immediate 0 so the UI transitions out of "Loading" copy
        // the moment we begin.
        event(.progress(DownloadMetrics(
            fraction: Double(completedBytes) / Double(max(totalBytes, 1)),
            bytesWritten: completedBytes,
            totalBytes: totalBytes,
            bytesPerSecond: 0,
            secondsRemaining: nil
        )))

        // Sequential file downloads. Parallel would gain nothing (HTTP/2
        // multiplexes; iOS caps connections per host at 4; one file is
        // 99.9% of bytes anyway) and lose clarity in the delegate routing.
        for file in sorted {
            try Task.checkCancellation()
            try await downloadFileWithRetries(
                baseURL: baseURL,
                file: file,
                destinationDir: destinationDir
            )
            let metrics = lock.withLock { () -> DownloadMetrics in
                completedByteBase += file.size
                return snapshotMetricsLocked()
            }
            event(.progress(metrics))
        }
    }

    /// Cancel the active download, persist resume data, emit .paused.
    /// No-op if nothing is in flight. Safe to call while already canceled.
    func cancelAndPersistResume() async {
        let task = lock.withLock { () -> URLSessionDownloadTask? in
            let candidate = taskStates.first(where: { $0.value.task != nil })
            if let candidate {
                pendingCancelForTask.insert(candidate.key)
                return candidate.value.task
            }
            return nil
        }
        guard let task else {
            onEvent?(.paused(DownloadMetrics.zero))
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            task.cancel(byProducingResumeData: { [weak self] data in
                guard let self else { cont.resume(); return }
                if let data {
                    self.persistResumeData(data)
                }
                let metrics = self.lock.withLock { self.snapshotMetricsLocked() }
                self.onEvent?(.paused(metrics))
                cont.resume()
            })
        }
    }

    // Note: Removed the app-global `hasResumeData` / `clearResumeData`
    // statics. Resume data is now scoped per MLXModelSpec — check
    // `MLXModelSpec.hasPartialDownload` and call
    // `MLXModelSpec.deleteDownloadedFiles()` to wipe it.

    /// One-shot: allow cellular for the CURRENT run only. Does not flip
    /// the persistent preference.
    func useCellularThisTime() {
        lock.withLock { wifiGatedSnapshot = false }
        let metrics = lock.withLock { snapshotMetricsLocked() }
        onEvent?(.progress(metrics))
    }

    // MARK: - Per-file retry loop (classic downloadTask + continuation)

    private func downloadFileWithRetries(
        baseURL: URL,
        file: FileSpec,
        destinationDir: URL
    ) async throws {
        let url = baseURL.appending(path: file.name)
        let destPath = destinationDir.appending(path: file.name)

        var resumeData = self.loadPersistedResumeData()
        var lastError: Error?

        for attempt in 1...DownloadTuning.maxAttemptsPerFile {
            try Task.checkCancellation()

            // Wi-Fi gate check BEFORE launching the task.
            let gated = lock.withLock { wifiGatedSnapshot }
            if gated {
                let metrics = lock.withLock { snapshotMetricsLocked() }
                onEvent?(.waitingForWifi(metrics))
                // Wait until gate clears (cellular allowed, Wi-Fi arrives,
                // or useCellularThisTime was called).
                try await waitForWifiClear()
            }

            do {
                let tempURL = try await runOneDownload(
                    url: url,
                    file: file,
                    resumeData: resumeData,
                    destPath: destPath
                )

                // Hash verify before moving to final destination.
                let ok = await hashMatches(path: tempURL, expected: file.sha256)
                if !ok {
                    try? FileManager.default.removeItem(at: tempURL)
                    log.warning("hash mismatch for \(file.name, privacy: .public) on attempt \(attempt)")
                    lastError = DownloadError.hashMismatch(file: file.name)
                    resumeData = nil
                    if attempt < DownloadTuning.maxAttemptsPerFile {
                        try await backoff(attempt: attempt)
                        continue
                    }
                    throw DownloadError.hashMismatch(file: file.name)
                }

                try? FileManager.default.removeItem(at: destPath)
                try FileManager.default.moveItem(at: tempURL, to: destPath)
                // Successful file → clear any persisted resume data since
                // it belongs to a superseded attempt.
                self.clearPersistedResumeData()
                return

            } catch is CancellationError {
                throw CancellationError()
            } catch let urlError as URLError where urlError.code == .cancelled {
                // Task-level cancel. Could be a user cancel (which is
                // terminal + resume data already persisted) or an
                // internal retry cancel.
                let wasUserCancel = lock.withLock { !pendingCancelForTask.isEmpty }
                if wasUserCancel {
                    throw DownloadError.canceledByUser
                }
                throw CancellationError()
            } catch let error {
                lastError = error
                log.warning("download \(file.name, privacy: .public) attempt \(attempt) failed: \(String(describing: error), privacy: .public)")

                if let urlError = error as? URLError,
                   let data = urlError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                    resumeData = data
                } else {
                    resumeData = nil
                }

                guard attempt < DownloadTuning.maxAttemptsPerFile, isRetryable(error) else {
                    throw error
                }
                try await backoff(attempt: attempt)
            }
        }

        throw DownloadError.exhaustedRetries(
            file: file.name,
            underlying: String(describing: lastError ?? DownloadError.missingResponse(file: file.name))
        )
    }

    /// Bridge: launch one URLSessionDownloadTask and await its completion
    /// via a CheckedContinuation. Handles both the resume-data path and
    /// the fresh-URL path.
    private func runOneDownload(
        url: URL,
        file: FileSpec,
        resumeData: Data?,
        destPath: URL
    ) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                let task: URLSessionDownloadTask
                if let resumeData {
                    task = session.downloadTask(withResumeData: resumeData)
                } else {
                    var request = URLRequest(url: url)
                    // Respect per-file cellular gate. URLSession-level is
                    // true; this gate is the user-preference-backed one.
                    request.allowsCellularAccess = lock.withLock { cellularAllowed }
                    task = session.downloadTask(with: request)
                }

                let state = TaskState(
                    file: file,
                    destPath: destPath,
                    task: task,
                    continuation: cont,
                    speedWindow: SpeedWindow()
                )
                lock.withLock {
                    taskStates[task.taskIdentifier] = state
                }
                task.resume()
            }
        } onCancel: {
            // Swift Task cancellation → propagate to URLSession.
            let tasks = lock.withLock { taskStates.values.compactMap { $0.task } }
            for t in tasks { t.cancel() }
        }
    }

    private func backoff(attempt: Int) async throws {
        let index = min(attempt - 1, DownloadTuning.backoffSeconds.count - 1)
        let seconds = DownloadTuning.backoffSeconds[index]
        try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
    }

    /// Blocks until wifiGatedSnapshot clears. Cheap polling is fine here:
    /// this loop only runs while the user is in the "Waiting for Wi-Fi…"
    /// state, which is intrinsically low-urgency.
    private func waitForWifiClear() async throws {
        while true {
            try Task.checkCancellation()
            let gated = lock.withLock { wifiGatedSnapshot }
            if !gated { return }
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 s
        }
    }

    private func isRetryable(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .networkConnectionLost,
                 .timedOut,
                 .cannotConnectToHost,
                 .cannotFindHost,
                 .notConnectedToInternet,
                 .dnsLookupFailed,
                 .resourceUnavailable,
                 .badServerResponse,
                 .secureConnectionFailed,
                 .httpTooManyRedirects:
                return true
            default:
                return false
            }
        }
        if let de = error as? DownloadError {
            switch de {
            case .hashMismatch, .missingResponse:        return true
            case .httpError(_, let s):                   return s >= 500
            case .exhaustedRetries, .canceledByUser,
                 .cellularDisallowed:                    return false
            }
        }
        return false
    }

    private func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let maybeMetrics = lock.withLock { () -> DownloadMetrics? in
            guard taskStates[downloadTask.taskIdentifier] != nil else { return nil }
            taskStates[downloadTask.taskIdentifier]?.speedWindow.record(totalBytes: totalBytesWritten)
            taskStates[downloadTask.taskIdentifier]?.bytesWrittenThisFile = totalBytesWritten
            guard let state = taskStates[downloadTask.taskIdentifier] else { return nil }

            // Throttle emission: only update the UI if enough wall-clock
            // time has passed OR enough progress delta has accumulated.
            let now = Date()
            let totalBytes = totalManifestBytes
            let currentOverall = completedByteBase + totalBytesWritten
            let fraction = totalBytes > 0 ? Double(currentOverall) / Double(totalBytes) : 0
            let shouldEmit: Bool = {
                if let last = lastEmitTime,
                   now.timeIntervalSince(last) < DownloadTuning.progressEmitInterval,
                   abs(fraction - lastEmitFraction) < DownloadTuning.progressEmitMinDelta {
                    return false
                }
                return true
            }()
            guard shouldEmit else { return nil }
            lastEmitTime = now
            lastEmitFraction = fraction

            return DownloadMetrics(
                fraction: min(1.0, fraction),
                bytesWritten: currentOverall,
                totalBytes: totalBytes,
                bytesPerSecond: state.speedWindow.bytesPerSecond,
                secondsRemaining: state.speedWindow.secondsRemaining(
                    totalExpectedBytes: state.file.size
                ).map { remaining in
                    // The rate is per-file but we want ETA for the whole
                    // run. Assuming the big file dominates (2.26 GB of
                    // 2.3 GB), per-file ETA is a close-enough approximation
                    // for total ETA — and any other approach would
                    // oscillate wildly as tiny files finish.
                    remaining
                }
            )
        }
        if let metrics = maybeMetrics {
            onEvent?(.progress(metrics))
        }
    }

    /// Throttle state for didWriteData emissions. Lock-protected.
    private var lastEmitTime: Date?
    private var lastEmitFraction: Double = 0

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // CRITICAL: iOS deletes `location` the moment this callback
        // returns. We MUST move/copy synchronously. Only fire the
        // continuation after the move is done (success) or as a failure
        // if the move itself fails.
        let (stateOpt, _) = lock.withLock { () -> (TaskState?, Bool) in
            guard let state = taskStates[downloadTask.taskIdentifier] else {
                return (nil, false)
            }
            return (state, true)
        }
        guard let state = stateOpt else { return }

        // Move to an intermediate path inside the destination dir so the
        // async caller can rehash before finalising. We use the destPath
        // + ".incoming" so failure doesn't leave half-written bytes at
        // the real destination.
        let intermediate = state.destPath
            .deletingLastPathComponent()
            .appending(path: ".\(state.file.name).incoming")
        do {
            try? FileManager.default.removeItem(at: intermediate)
            try FileManager.default.moveItem(at: location, to: intermediate)
            fireOnce(taskIdentifier: downloadTask.taskIdentifier, result: .success(intermediate))
        } catch {
            fireOnce(taskIdentifier: downloadTask.taskIdentifier, result: .failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            fireOnce(taskIdentifier: task.taskIdentifier, result: .failure(error))
        }
        // Success path: didFinishDownloadingTo already fired and consumed
        // the continuation. Single-fire guard swallows the duplicate.
        lock.withLock {
            taskStates.removeValue(forKey: task.taskIdentifier)
            pendingCancelForTask.remove(task.taskIdentifier)
        }
    }

    func urlSession(
        _ session: URLSession,
        taskIsWaitingForConnectivity task: URLSessionTask
    ) {
        let metrics = lock.withLock { snapshotMetricsLocked() }
        onEvent?(.waitingForNetwork(metrics))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // Apple's requirement: call the handler after delivering all
        // pending events, so iOS knows we've processed everything and
        // doesn't mark the session misbehaving.
        let handler = lock.withLock { () -> (() -> Void)? in
            let h = backgroundCompletionHandler
            backgroundCompletionHandler = nil
            return h
        }
        DispatchQueue.main.async {
            handler?()
        }
    }

    // MARK: - Private helpers

    /// Single-fire continuation resume. Multiple delegate callbacks can
    /// want to finish the same task (success fires didFinishDownloadingTo
    /// then didCompleteWithError with no error). Only the first one wins.
    private func fireOnce(taskIdentifier: Int, result: Result<URL, Error>) {
        let cont = lock.withLock { () -> CheckedContinuation<URL, Error>? in
            guard let state = taskStates[taskIdentifier], !state.didFire else { return nil }
            let c = state.continuation
            taskStates[taskIdentifier]?.didFire = true
            taskStates[taskIdentifier]?.continuation = nil
            return c
        }
        guard let cont else { return }
        switch result {
        case .success(let url): cont.resume(returning: url)
        case .failure(let err): cont.resume(throwing: err)
        }
    }

    /// Compute DownloadMetrics from current state. Must be called under
    /// lock.
    private func snapshotMetricsLocked() -> DownloadMetrics {
        let inFlightBytes = taskStates.values.reduce(Int64(0)) { $0 + $1.bytesWrittenThisFile }
        let overall = completedByteBase + inFlightBytes
        let total = totalManifestBytes
        let fraction = total > 0 ? Double(overall) / Double(total) : 0
        let rate = taskStates.values.first?.speedWindow.bytesPerSecond ?? 0
        return DownloadMetrics(
            fraction: min(1.0, fraction),
            bytesWritten: overall,
            totalBytes: total,
            bytesPerSecond: rate,
            secondsRemaining: nil
        )
    }

    /// Streaming SHA-256 on a background detached task. The 2 GB
    /// safetensors takes ~10 s on an iPhone; doing it on the actor would
    /// block other work.
    private func hashMatches(path: URL, expected: String) async -> Bool {
        await Task.detached {
            guard let handle = try? FileHandle(forReadingFrom: path) else { return false }
            defer { try? handle.close() }
            var hasher = SHA256()
            let chunkSize = DownloadTuning.hashChunkSize
            while autoreleasepool(invoking: {
                guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                    return false
                }
                hasher.update(data: chunk)
                return true
            }) {}
            let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return hex == expected
        }.value
    }
}

// MARK: - Per-task state

private struct TaskState {
    let file: FileSpec
    let destPath: URL
    var task: URLSessionDownloadTask?
    var continuation: CheckedContinuation<URL, Error>?
    var didFire: Bool = false
    var speedWindow: SpeedWindow
    var bytesWrittenThisFile: Int64 = 0
}

// Note: NSLock.withLock is provided by Foundation on iOS 16+ — no local
// extension needed. The rethrows overload covers our non-throwing closures.
