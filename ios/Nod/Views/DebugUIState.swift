// DebugUIState.swift
// Debug-only launch arguments that force hard-to-reach UI states, so
// every screen can be seen in the Simulator (which always has Apple
// Intelligence and can't run MLX):
//
//   -nodAFM notSupported | disabled | none
//       Pretend Apple Intelligence is unsupported, turned off, or that
//       nothing fits this phone ("none").
//   -nodDownload downloading | wifi | network | paused | loading |
//                failNetwork | failDisk | failOther
//       Show the download/readiness bar in that state.
//   -nodRecording YES
//       Show the dictation UI as if recording (stop button, edge glow).
//       Simulator voice input often lacks its language assets.
//   -nodLocked YES
//       Show the Face ID lock screen and keep it up (the Simulator
//       has no passcode, so it would otherwise unlock at once).
//
// Compiled out of release builds.

import Foundation

enum DebugUIState {
    #if DEBUG
    private static func argument(_ name: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static var forcedAFMStatus: DeviceCapability.AFMStatus? {
        switch argument("-nodAFM") {
        case "notSupported", "none": return .notSupported
        case "disabled": return .disabledInSettings
        default: return nil
        }
    }

    /// True when no downloadable model should fit ("-nodAFM none").
    static var forceNoMLX: Bool { argument("-nodAFM") == "none" }

    static var forceLocked: Bool { argument("-nodLocked") == "YES" }

    static var forceRecording: Bool { argument("-nodRecording") == "YES" }

    static var forcedDownloadState: MLXEngineClient.State? {
        let total = MLXModelSpec.qwen35_4b.totalBytes
        let partial = DownloadMetrics(
            fraction: 0.42, bytesWritten: Int64(Double(total) * 0.42), totalBytes: total,
            bytesPerSecond: 8_500_000, secondsRemaining: 210
        )
        switch argument("-nodDownload") {
        case "downloading": return .downloading(partial)
        case "wifi": return .waitingForWifi(partial.frozen())
        case "network": return .waitingForNetwork(partial.frozen())
        case "paused": return .paused(partial.frozen())
        case "loading": return .loading
        case "failNetwork": return .failed("downloadFailedNoNetwork")
        case "failDisk": return .failed("downloadFailedDiskFull")
        case "failOther": return .failed("modelLoadFailed")
        default: return nil
        }
    }
    #else
    static let forcedAFMStatus: DeviceCapability.AFMStatus? = nil
    static let forceNoMLX = false
    static let forceLocked = false
    static let forceRecording = false
    static let forcedDownloadState: MLXEngineClient.State? = nil
    #endif
}
