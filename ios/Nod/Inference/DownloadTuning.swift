// DownloadTuning.swift
// One-place tuning for the Qwen download. Having the magic numbers here
// means a future reviewer doesn't have to hunt through four files to
// understand why the UI updates ~5 times per second instead of 50, or
// why we back off 2/5/10 seconds instead of 1/2/4.

import Foundation

enum DownloadTuning {

    // MARK: - Throttling

    /// Minimum wall-clock time between UI progress emissions. At ~3 MB/s on
    /// iPhone, didWriteData fires dozens of times per second. Emitting all
    /// of them would flood @Published → SwiftUI → layout and cost more CPU
    /// than the download itself. 100 ms gives a visibly smooth bar (10 fps
    /// for progress updates is plenty; the bar interpolates between frames).
    static let progressEmitInterval: TimeInterval = 0.1

    /// Minimum fractional progress delta that forces an emit even if the
    /// last emit was <100 ms ago. On a 2.3 GB download this is ~11 MB of
    /// progress — meaningful enough to be worth skipping the throttle for.
    static let progressEmitMinDelta: Double = 0.005

    // MARK: - Rolling speed window

    /// Lookback window for the bytes-per-second calculation. We display
    /// speed rounded to the nearest whole MB/s (see ChatView.formatCoarse-
    /// Speed), which gets jittery on a short window — the averaged rate
    /// oscillates across an integer boundary ("3 MB/s ↔ 4 MB/s"). A
    /// 10-second window smooths that across enough samples to keep the
    /// displayed number stable for the duration of the download, while
    /// still responding to genuine rate changes (Wi-Fi → cellular, etc.)
    /// inside two breaths.
    static let speedWindowSeconds: TimeInterval = 10.0

    // MARK: - Retry / backoff

    /// Per-file download attempt ceiling. Transient issues (flaky Wi-Fi,
    /// CDN hiccup) almost always clear inside 3 attempts; anything past
    /// that is a real problem and blocking the user with more retries is
    /// rude.
    static let maxAttemptsPerFile = 3

    /// Backoff sequence in seconds. Intentionally asymmetric — the first
    /// retry is fast (most failures are transient and resolve in <5 s) and
    /// the later retries are wider (gives real congestion time to settle).
    static let backoffSeconds: [Int] = [2, 5, 10]

    // MARK: - Timeouts

    /// Request-level timeout. A single HTTP request for one file stalling
    /// for 60 s means the connection is dead even if the socket isn't
    /// closed yet. URLSession's defaults would wait forever.
    static let timeoutIntervalForRequest: TimeInterval = 60

    /// Resource-level timeout. The whole 2.3 GB must finish within this
    /// wall-clock window. 7200 s (2 hr) covers a slow cellular connection
    /// without declaring it dead prematurely.
    static let timeoutIntervalForResource: TimeInterval = 7200

    // MARK: - Relocked grace

    /// When the user hits Cancel, we immediately persist the resume data
    /// to disk. This is the filename.
    static let resumeDataFilename = "qwen-download-resume.data"

    // MARK: - Background session identity

    /// Stable identifier for the background URLSession. iOS uses this to
    /// route delegate callbacks when the app is killed and relaunched
    /// mid-download. The session identifier must be unique to this app
    /// bundle and must not change across app versions — otherwise iOS
    /// can't reattach to in-flight tasks from a previous launch.
    static let backgroundSessionIdentifier = "app.usenod.nod.qwen-download"

    // MARK: - SHA-256 streaming

    /// Chunk size for streaming hash computation. 1 MB keeps a 2 GB file
    /// from trying to live in RAM and still amortises FileHandle overhead.
    static let hashChunkSize = 1 << 20
}
