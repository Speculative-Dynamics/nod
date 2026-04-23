// DownloadMetrics.swift
// What the UI shows on a downloading-state card. Carried inside the
// MLXEngineClient.State enum cases that can show progress (.downloading,
// .waitingForNetwork, .waitingForWifi, .paused). Bundling all the numbers
// into one struct keeps the state cases small and makes equality checks
// efficient.

import Foundation

struct DownloadMetrics: Equatable, Sendable {
    /// 0.0 ... 1.0 across ALL files that need downloading this run.
    /// Files already present on disk don't contribute to either numerator
    /// or denominator — this is progress on the NEW bytes only.
    let fraction: Double

    /// Bytes completed so far (including already-present files trusted on
    /// reopen). Used for the "721 MB of 2.3 GB" display.
    let bytesWritten: Int64

    /// Total bytes across all files in the manifest.
    let totalBytes: Int64

    /// Rolling-window byte rate. Zero in paused/waiting states because
    /// nothing's moving.
    let bytesPerSecond: Double

    /// Estimated seconds to finish. Nil when:
    /// - We don't have a stable rate yet (first ~1 s of a fresh download).
    /// - The download is paused or waiting.
    /// - The rate dropped to zero.
    /// UI shows this only when non-nil; otherwise shows the byte count
    /// and nothing else.
    let secondsRemaining: TimeInterval?

    static let zero = DownloadMetrics(
        fraction: 0,
        bytesWritten: 0,
        totalBytes: 0,
        bytesPerSecond: 0,
        secondsRemaining: nil
    )

    /// Clone with the rate nulled out. Used when transitioning to a
    /// paused-ish state (network lost, Wi-Fi required, user canceled) —
    /// the card keeps showing bytes-so-far but the speed/ETA line goes
    /// quiet instead of showing a stale last-known-rate.
    func frozen() -> DownloadMetrics {
        DownloadMetrics(
            fraction: fraction,
            bytesWritten: bytesWritten,
            totalBytes: totalBytes,
            bytesPerSecond: 0,
            secondsRemaining: nil
        )
    }
}
