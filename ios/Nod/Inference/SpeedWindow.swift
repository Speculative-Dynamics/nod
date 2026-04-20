// SpeedWindow.swift
// Rolling-window byte-rate calculation. Pure struct, no IO. Given a stream
// of (totalBytesWritten, timestamp) samples, reports the byte rate across
// the most recent `windowSeconds` of samples.
//
// Why not just (currentBytes - startBytes) / totalElapsed? Because that
// averages over the whole download, which means the speed reading barely
// moves as you progress. Users want "what's my speed RIGHT NOW" — which is
// "over the last few seconds." Hence the rolling window.

import Foundation

struct SpeedWindow {

    private struct Sample {
        let timestamp: Date
        let bytes: Int64
    }

    private var samples: [Sample] = []
    private let windowSeconds: TimeInterval

    init(windowSeconds: TimeInterval = DownloadTuning.speedWindowSeconds) {
        self.windowSeconds = windowSeconds
    }

    /// Record the current total byte count at `time`. Trims samples older
    /// than the window. `totalBytes` must be monotonically non-decreasing
    /// (it's "bytes downloaded so far" — if it ever decreases that means
    /// a resume/retry reset, and we clear the window rather than report
    /// a nonsense negative rate).
    mutating func record(totalBytes: Int64, at time: Date = Date()) {
        // Resume/retry detection: if the byte counter went backward, the
        // previous window is now meaningless. Start fresh.
        if let last = samples.last, totalBytes < last.bytes {
            samples.removeAll()
        }
        samples.append(Sample(timestamp: time, bytes: totalBytes))
        let cutoff = time.addingTimeInterval(-windowSeconds)
        // Keep at least one sample around so a long pause doesn't lose all
        // context — otherwise bytesPerSecond would read 0 for ever-longer
        // stretches of idle time.
        while samples.count > 1, let first = samples.first, first.timestamp < cutoff {
            samples.removeFirst()
        }
    }

    /// Bytes per second across the current window. Returns 0 if fewer than
    /// two samples exist (can't compute a rate from one point) or if the
    /// samples span less than 100 ms (not enough signal; would produce
    /// wildly noisy rates).
    var bytesPerSecond: Double {
        guard samples.count >= 2,
              let first = samples.first,
              let last = samples.last else { return 0 }
        let duration = last.timestamp.timeIntervalSince(first.timestamp)
        guard duration >= 0.1 else { return 0 }
        let byteDelta = Double(last.bytes - first.bytes)
        return max(0, byteDelta / duration)
    }

    /// Estimated seconds to finish, given total expected bytes and the
    /// most recent sample's written-so-far count. Returns nil if we don't
    /// have a stable rate yet, or if expected <= written (already done).
    func secondsRemaining(totalExpectedBytes: Int64) -> TimeInterval? {
        let rate = bytesPerSecond
        guard rate > 0 else { return nil }
        guard let last = samples.last else { return nil }
        let remaining = totalExpectedBytes - last.bytes
        guard remaining > 0 else { return nil }
        return Double(remaining) / rate
    }

    /// Clear the window. Used when switching from one file to the next so
    /// that a tiny JSON file completing at 30 MB/s doesn't leave a stale
    /// rate for the start of the 2.26 GB safetensors.
    mutating func reset() {
        samples.removeAll()
    }
}
