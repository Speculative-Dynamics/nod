// DownloadEvent.swift
// The discriminated union MLXR2BackgroundSession uses to tell MLXEngineClient
// what happened. Kept separate from State because events are what the
// session reports; State is what the UI sees. The mapping is cheap and
// explicit in MLXEngineClient.applyDownloadEvent.

import Foundation

enum DownloadEvent: Sendable {
    /// Normal progress tick. Fires throttled (~10 fps) during an active
    /// download. When metrics.fraction >= 1.0 the session transitions
    /// into MLX load, not another progress tick.
    case progress(DownloadMetrics)

    /// No connectivity at all. URLSession's waitsForConnectivity puts the
    /// request into this state. When connectivity returns, the session
    /// resumes and emits .progress again.
    case waitingForNetwork(DownloadMetrics)

    /// Cellular download disallowed by preference; current path is
    /// cellular. Cleared on: user flips the persistent toggle, user taps
    /// "Use cellular this time", or the path switches to Wi-Fi.
    case waitingForWifi(DownloadMetrics)

    /// User explicitly canceled. Resume data persisted to disk.
    case paused(DownloadMetrics)
}
