// QwenR2Downloader.swift
// Downloads the Qwen 3 4B (4-bit) MLX weights from our Cloudflare R2 bucket
// into Application Support, verifying each file's SHA-256 on arrival.
//
// Why R2 instead of Hugging Face's Hub:
//   - HF's public endpoints are rate-limited. At any real install count we
//     expect throttling to surface as mysterious download failures.
//   - R2 egress is free, which means predictable delivery for large files
//     without surprise bills.
//   - The model weights are already public (mlx-community/Qwen3-4B-4bit on
//     HF), so re-hosting them doesn't raise licensing concerns.
//
// Why foreground URLSession (not background):
//   Background URLSessions are throttled by iOS — they run in nsurlsessiond
//   which the system deprioritises behind anything in the foreground. For a
//   2 GB download, that can turn a 5-minute wait into an hours-long wait.
//   We use a foreground session for speed, and the caller UI keeps the
//   screen awake via UIApplication.isIdleTimerDisabled during the download
//   so a phone-in-pocket doesn't kill the transfer.
//
// Where files land:
//   <Application Support>/Nod/Qwen3-4B-4bit/<file>
//
// Application Support is hidden from the Files app, isn't backed up to
// iCloud by default (which would waste the user's quota with 2 GB of
// weights), and isn't evictable the way Caches is.
//
// Integrity:
//   Each file ships with a SHA-256 baked into QwenClient's file manifest.
//   After download we stream-hash the file and reject any mismatch with
//   hashMismatch, deleting the bad bytes so a retry gets a clean state.
//   Streaming (1 MB chunks) keeps the big 2 GB safetensors off the heap.
//
// Resilience:
//   Each file gets up to 3 attempts with exponential backoff. Transient
//   network drops mid-stream (the common -1005 case on flaky Wi-Fi) use
//   URLSession's resumeData so a failure at 90% resumes at 90%, not zero.
//   Permanent failures (4xx, auth) short-circuit to a user-facing failure
//   immediately.
//
// Observability:
//   Warnings and errors only — under subsystem `app.usenod.nod`, category
//   `qwen.download`. Filter in Console.app on device to surface hash
//   mismatches and per-attempt failures without drowning in per-chunk noise.

import CryptoKit
import Foundation
import os

private let log = Logger(subsystem: "app.usenod.nod", category: "qwen.download")

enum QwenR2Downloader {

    struct FileSpec: Sendable {
        let name: String
        let sha256: String
        let size: Int64
    }

    enum DownloadError: Error, CustomStringConvertible {
        case hashMismatch(file: String)
        case httpError(file: String, status: Int)
        case missingResponse(file: String)
        case exhaustedRetries(file: String, underlying: String)

        var description: String {
            switch self {
            case .hashMismatch(let f):            return "SHA-256 mismatch for \(f)"
            case .httpError(let f, let s):        return "HTTP \(s) fetching \(f)"
            case .missingResponse(let f):         return "No HTTP response for \(f)"
            case .exhaustedRetries(let f, let u): return "Exhausted retries for \(f): \(u)"
            }
        }
    }

    /// Ensure every file in `files` is present and verified under `destinationDir`.
    /// Skips files already on disk with a matching size (we trust earlier
    /// download-time hash checks — rehashing the 2 GB safetensors on every
    /// launch adds ~15 s of "Loading…" dead time for no real safety gain).
    ///
    /// Progress is reported in [0, 1] across the total byte count of the
    /// files that need downloading (files already present contribute 0).
    static func ensureLocalFiles(
        baseURL: URL,
        files: [FileSpec],
        destinationDir: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try FileManager.default.createDirectory(
            at: destinationDir,
            withIntermediateDirectories: true
        )

        // On reopen, trust files that are already at their final destination.
        // We move to destPath only after the download-time hash check passes,
        // so a present file with matching size was verified once and hasn't
        // been touched since (Application Support is sandboxed, not user-
        // editable). Skipping the rehash saves ~15 s of "Loading…" dead time
        // on every launch of the 2 GB safetensors.
        //
        // If size disagrees, the file is a partial or leftover — remove it
        // and re-download from scratch.
        var toDownload: [FileSpec] = []
        for f in files {
            let path = destinationDir.appending(path: f.name)
            if FileManager.default.fileExists(atPath: path.path) {
                let actualSize = (try? FileManager.default
                    .attributesOfItem(atPath: path.path)[.size] as? Int64) ?? -1
                if actualSize == f.size {
                    continue
                }
                try? FileManager.default.removeItem(at: path)
            }
            toDownload.append(f)
        }

        if toDownload.isEmpty {
            progress(1.0)
            return
        }

        // Sort largest-first so the progress bar moves meaningfully from the
        // start. Otherwise the tiny tokenizer/config files at ~1 MB barely
        // register against a 2 GB total and the UI looks frozen.
        toDownload.sort { $0.size > $1.size }

        // Emit an immediate 0-ish progress so the UI transitions out of the
        // generic "Loading" copy into "Downloading" even before the first
        // HTTP byte arrives.
        progress(0.0)

        let totalBytes = toDownload.reduce(Int64(0)) { $0 + $1.size }
        var completedBytes: Int64 = 0

        // Long resource timeout so a 2 GB file on slow Wi-Fi doesn't die.
        // waitsForConnectivity lets the task pause and resume on the user's
        // behalf when connectivity blips.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7200
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config)

        for file in toDownload {
            try Task.checkCancellation()

            let baseCompleted = completedBytes
            try await downloadFileWithRetries(
                session: session,
                baseURL: baseURL,
                file: file,
                destinationDir: destinationDir,
                onBytes: { downloaded in
                    let overall = Double(baseCompleted + downloaded) / Double(max(totalBytes, 1))
                    progress(min(1.0, overall))
                }
            )

            completedBytes += file.size
            progress(Double(completedBytes) / Double(max(totalBytes, 1)))
        }
    }

    // MARK: - Retry loop

    /// Download one file with up to 3 attempts. Transient errors (network
    /// drops, timeouts, 5xx, hash mismatches) back off and retry; auth and
    /// 4xx bail immediately. Uses URLSession resumeData on mid-stream drops
    /// when the server returned byte-range support (R2 does) so a failure
    /// at 90 % resumes at 90 %, not zero.
    private static func downloadFileWithRetries(
        session: URLSession,
        baseURL: URL,
        file: FileSpec,
        destinationDir: URL,
        onBytes: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let url = baseURL.appending(path: file.name)
        let destPath = destinationDir.appending(path: file.name)
        let maxAttempts = 3
        var resumeData: Data? = nil
        var lastError: Error?

        for attempt in 1...maxAttempts {
            try Task.checkCancellation()

            do {
                let tempURL = try await downloadOneFile(
                    session: session,
                    url: url,
                    file: file,
                    resumeData: resumeData,
                    onBytes: onBytes
                )

                // Stream-hash the temp file. For a 2 GB safetensors this is
                // noticeable but unavoidable — without verification a single
                // truncated response could silently brick every launch.
                let tempMatches = await hashMatches(path: tempURL, expected: file.sha256)
                if !tempMatches {
                    try? FileManager.default.removeItem(at: tempURL)
                    log.warning("hash mismatch for \(file.name, privacy: .public) on attempt \(attempt)")
                    lastError = DownloadError.hashMismatch(file: file.name)
                    resumeData = nil // corrupt bytes; can't resume, start fresh
                    if attempt < maxAttempts {
                        try await backoff(attempt: attempt)
                        continue
                    }
                    throw DownloadError.hashMismatch(file: file.name)
                }

                try? FileManager.default.removeItem(at: destPath)
                try FileManager.default.moveItem(at: tempURL, to: destPath)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch let urlError as URLError where urlError.code == .cancelled {
                throw CancellationError()
            } catch let error {
                lastError = error
                log.warning("download \(file.name, privacy: .public) attempt \(attempt) failed: \(String(describing: error), privacy: .public)")

                // Pull resumeData off the URLError if the server/connection
                // left us something to resume from. Clearing it means we
                // re-download from zero on the next attempt.
                if let urlError = error as? URLError,
                   let data = urlError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                    resumeData = data
                } else {
                    resumeData = nil
                }

                guard attempt < maxAttempts, isRetryable(error) else {
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

    /// Non-retryable errors short-circuit the retry loop. The typical
    /// example is HTTP 404 (wrong URL) or 403 (access revoked) — no amount
    /// of backoff will fix those, and blocking the user for 20 seconds of
    /// retries before surfacing a permanent error is rude.
    private static func isRetryable(_ error: Error) -> Bool {
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
            case .hashMismatch:               return true
            case .missingResponse:            return true
            case .httpError(_, let s):        return s >= 500
            case .exhaustedRetries:           return false
            }
        }
        return false
    }

    /// Exponential-ish backoff: 2 s, 5 s, 10 s. Short enough that a real
    /// user doesn't abandon; long enough to let transient congestion or
    /// radio wake-ups settle.
    private static func backoff(attempt: Int) async throws {
        let seconds: Int = attempt == 1 ? 2 : attempt == 2 ? 5 : 10
        try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
    }

    // MARK: - Per-file download

    private static func downloadOneFile(
        session: URLSession,
        url: URL,
        file: FileSpec,
        resumeData: Data?,
        onBytes: @escaping @Sendable (Int64) -> Void
    ) async throws -> URL {
        let delegate = ProgressDelegate(onBytes: onBytes)
        let tempURL: URL
        let response: URLResponse
        if let resumeData {
            (tempURL, response) = try await session.download(resumeFrom: resumeData, delegate: delegate)
        } else {
            (tempURL, response) = try await session.download(from: url, delegate: delegate)
        }

        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: tempURL)
            throw DownloadError.missingResponse(file: file.name)
        }
        // 200 OK for fresh downloads, 206 Partial Content when resuming.
        guard http.statusCode == 200 || http.statusCode == 206 else {
            try? FileManager.default.removeItem(at: tempURL)
            throw DownloadError.httpError(file: file.name, status: http.statusCode)
        }
        return tempURL
    }

    // MARK: - Internals

    /// Streaming SHA-256. Reads the file in 1 MB chunks so the 2 GB
    /// safetensors doesn't try to live in RAM all at once. Runs on a
    /// detached task so the Qwen actor isn't blocked during the ~10s
    /// hash on a phone.
    private static func hashMatches(path: URL, expected: String) async -> Bool {
        await Task.detached {
            guard let handle = try? FileHandle(forReadingFrom: path) else { return false }
            defer { try? handle.close() }
            var hasher = SHA256()
            let chunkSize = 1 << 20
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

/// Translates URLSessionDownloadDelegate progress into a sendable byte-count
/// callback. `@unchecked Sendable` is fine here because we only read the
/// immutable `onBytes` closure; no mutable state.
private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onBytes: @Sendable (Int64) -> Void

    init(onBytes: @escaping @Sendable (Int64) -> Void) {
        self.onBytes = onBytes
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The async `session.download(from:)` API returns the temp URL to
        // the caller; nothing to do here.
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onBytes(totalBytesWritten)
    }
}
