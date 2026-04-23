// DictationRecognizer.swift
// iOS 26 Speech-to-text using Apple's new SpeechAnalyzer + SpeechTranscriber.
//
// Why this rewrite (from SFSpeechRecognizer): the previous version made
// the class @MainActor, so sync calls like AVAudioSession.setActive,
// engine.prepare, and engine.start blocked the main thread. UI froze.
// See https://useyourloaf.com/blog/swiftui-tasks-blocking-the-mainactor/
//
// Architecture:
//   1. Class is @MainActor for SwiftUI state updates via @Published.
//   2. Heavy audio/engine setup runs inside `Task.detached` so it
//      truly leaves the main actor. The detached task owns the
//      setup work; it hops back to main actor only for @Published
//      state mutations.
//   3. Audio resources (engine, transcriber, analyzer, continuation)
//      are stored with `nonisolated(unsafe)` because they are
//      reference-type singletons touched serially from setup and
//      teardown paths. Safe in practice, ugly but clear.
//   4. SpeechAnalyzer + SpeechTranscriber replaces SFSpeechRecognizer.
//      Results come via `transcriber.results` AsyncSequence, which is
//      designed for Swift concurrency from the ground up.
//
// Public API preserved so ChatView doesn't need rewiring:
//   state, isUnavailableForSession, lastFinalText, start(), commit(),
//   cancel().

import AVFoundation
import Combine
import Foundation
import OSLog
import Speech

// AVAudioPCMBuffer doesn't declare Sendable, but Apple's sample code
// for SpeechAnalyzer crosses it across actor boundaries via AsyncStream.
// Retroactive conformance at file scope is the canonical workaround.
// PCM buffers from an input tap are immutable once captured, so there's
// no actual unsafe aliasing.
extension AVAudioPCMBuffer: @unchecked @retroactive Sendable {}

// MARK: - Nonisolated permission helpers
//
// File-scope nonisolated so the Obj-C completion callback (which iOS
// fires on a background queue) doesn't trip Swift 6's main-actor
// isolation check. Previously these were inline inside start() and
// crashed the app via SIGTRAP — the fix is to keep them at file scope.

private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
    await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
        SFSpeechRecognizer.requestAuthorization { status in
            continuation.resume(returning: status)
        }
    }
}

private func requestMicrophonePermission() async -> Bool {
    await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        AVAudioApplication.requestRecordPermission { granted in
            continuation.resume(returning: granted)
        }
    }
}

@MainActor
final class DictationRecognizer: ObservableObject {

    // MARK: - Public state

    enum State: Equatable {
        case idle
        case requestingPermission
        case listening
        case committed(final: String)
        case unavailable(UnavailableReason)
    }

    // Simplified from earlier. Previously State.listening carried
    // `partial: String` and `silenceProgress: Double`. Every partial
    // result and every 33ms progress tick mutated @Published state,
    // firing objectWillChange, which re-rendered ChatView's entire
    // body on every tick. Main actor saturated → app appeared frozen
    // (taps queued but never processed). Now partial text + silence
    // progress are tracked in private vars (below) that ChatView
    // does NOT observe. @Published `state` only changes on true
    // transitions (idle → listening → committed → idle), so ChatView
    // re-renders a handful of times per recording session instead of
    // hundreds per second.

    enum UnavailableReason: Equatable {
        case permissionDenied
        case recognizerUnavailable
        case audioEngineFailed
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var isUnavailableForSession = false
    private(set) var lastFinalText: String = ""

    /// Latest partial transcript. Updated every time the transcriber
    /// emits a non-final result. NOT @Published — ChatView doesn't
    /// observe it, so updates don't trigger ChatView re-renders.
    private var currentPartial: String = ""

    // MARK: - Private state

    private let log = Logger(subsystem: "app.usenod.nod", category: "voice")

    // Audio resources. `nonisolated(unsafe)` because:
    //   - AVAudioEngine/SpeechAnalyzer/SpeechTranscriber are classes
    //     (reference types).
    //   - They are accessed from the @MainActor-isolated class AND
    //     from the detached setup/teardown/analyze tasks.
    //   - Access is serialized via the state machine: we set these
    //     during setup, read them in teardown; no concurrent writes.
    nonisolated(unsafe) private var engine: AVAudioEngine?
    nonisolated(unsafe) private var transcriber: SpeechTranscriber?
    nonisolated(unsafe) private var analyzer: SpeechAnalyzer?
    nonisolated(unsafe) private var audioContinuation: AsyncStream<AnalyzerInput>.Continuation?

    // Tasks — main actor
    private var silenceTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var analyzeTask: Task<Void, Never>?
    private var finalizeTask: Task<Void, Never>?

    private var audioSessionActive = false
    private var tapInstalled = false
    private var startGeneration: Int = 0
    /// Set true when commit() begins finalization. Prevents silence
    /// timer + user tap from BOTH triggering commit() and racing two
    /// finalize sequences against the same analyzer.
    private var isFinalizing: Bool = false

    private let silenceTotal: TimeInterval = 2.5

    init() {}

    // MARK: - Public API

    func start() async {
        if case .listening = state { return }

        startGeneration &+= 1
        let gen = startGeneration
        // Clear any stale transcript from a previous session so
        // ChatView can't re-insert it if this session fails before
        // committing.
        lastFinalText = ""
        isFinalizing = false
        state = .requestingPermission

        // Step 1 — Speech recognition permission.
        let speechStatus = await requestSpeechAuthorization()
        guard gen == startGeneration else { return }
        guard speechStatus == .authorized else {
            state = .unavailable(.permissionDenied)
            return
        }

        // Step 2 — Mic permission.
        let micGranted = await requestMicrophonePermission()
        guard gen == startGeneration else { return }
        guard micGranted else {
            state = .unavailable(.permissionDenied)
            return
        }

        // Step 3 — Locale support for SpeechTranscriber.
        //
        // User's system locale can include regional subdivisions (e.g.
        // "en_US@rg=inzzzz" for a US-English speaker in India).
        // SpeechTranscriber.supportedLocales returns base locales like
        // "en-US" — exact BCP-47 match fails. Match on language code
        // first, then region as a tiebreaker, so the regional override
        // doesn't exclude a perfectly-supported language.
        let locale = Locale.current
        let supported = await SpeechTranscriber.supportedLocales
        let userLang = locale.language.languageCode?.identifier
        let userRegion = locale.language.region?.identifier

        // Best match: same language + same region (e.g. en + US).
        // Fallback: same language, any region (e.g. any "en").
        // Final fallback: first supported locale (should never be empty).
        let matched = supported.first(where: {
            $0.language.languageCode?.identifier == userLang
                && $0.language.region?.identifier == userRegion
        }) ?? supported.first(where: {
            $0.language.languageCode?.identifier == userLang
        })

        guard let resolvedLocale = matched else {
            isUnavailableForSession = true
            state = .unavailable(.recognizerUnavailable)
            return
        }

        // Step 4 — Heavy setup runs OFF main actor on a detached task.
        // This is load-bearing: every sync AVAudioSession / engine
        // call inside would block the main thread otherwise, freezing
        // the UI.
        let setupResult: SetupResult
        do {
            setupResult = try await Task.detached(priority: .userInitiated) {
                try await Self.performHeavySetup(locale: resolvedLocale)
            }.value
        } catch {
            guard gen == startGeneration else { return }
            log.error("Voice setup failed: \(error.localizedDescription, privacy: .public)")
            tearDownSync()
            state = .unavailable(.audioEngineFailed)
            return
        }

        // Back on main actor — store resources.
        guard gen == startGeneration else {
            // Abandoned while we awaited. Clean up the resources we
            // just created so the mic indicator doesn't linger.
            Self.tearDownResources(setupResult)
            return
        }

        self.engine = setupResult.engine
        self.transcriber = setupResult.transcriber
        self.analyzer = setupResult.analyzer
        self.audioContinuation = setupResult.continuation
        self.audioSessionActive = true
        self.tapInstalled = true

        // Analyze task — consumes the audio stream. Runs until the
        // stream finishes (we call continuation.finish() in teardown).
        let analyzer = setupResult.analyzer
        let analyzerStream = setupResult.analyzerStream
        self.analyzeTask = Task.detached(priority: .userInitiated) {
            do {
                try await analyzer.analyzeSequence(analyzerStream)
            } catch {
                // Expected on cancellation/teardown — don't flap state.
            }
        }

        // Results loop — hops to main for each transcriber result.
        let transcriber = setupResult.transcriber
        self.resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    await self?.handleTranscriberResult(result)
                }
            } catch {
                // Stream closed on teardown — normal.
            }
        }

        currentPartial = ""
        state = .listening
        resetSilenceTimer()
    }

    func commit() {
        // If user tapped stop while still in permission phase, treat
        // as cancel — bump generation so the in-flight setup bails
        // when it tries to transition to .listening.
        if case .requestingPermission = state {
            cancel()
            return
        }
        guard case .listening = state else {
            tearDownSync()
            return
        }
        let partial = currentPartial
        // Idempotent: don't launch a second finalize if one is
        // already in flight.
        if isFinalizing { return }
        isFinalizing = true

        // Cancel silence timer — we're finalizing now.
        silenceTask?.cancel(); silenceTask = nil

        // Finish the audio stream (signals analyzer that input ended).
        let continuation = audioContinuation
        let analyzer = self.analyzer
        finalizeTask?.cancel()
        finalizeTask = Task { [weak self] in
            continuation?.finish()
            do {
                try await analyzer?.finalizeAndFinishThroughEndOfInput()
            } catch {
                // Log only; we still fall through to fallback.
            }

            // Fallback: if no final result arrives in 700ms, commit
            // with the partial we had at commit-time.
            try? await Task.sleep(for: .milliseconds(700))
            await self?.fallbackFinalize(with: partial)
        }
    }

    func cancel() {
        startGeneration &+= 1
        if case .committed = state {
            // Commit already landed — preserve lastFinalText.
            tearDownSync()
            return
        }
        lastFinalText = ""
        tearDownSync()
        state = .idle
    }

    // MARK: - Heavy setup (OFF main actor)

    /// Setup result bundle — Sendable so it crosses actor boundaries.
    private struct SetupResult: @unchecked Sendable {
        let engine: AVAudioEngine
        let transcriber: SpeechTranscriber
        let analyzer: SpeechAnalyzer
        let continuation: AsyncStream<AnalyzerInput>.Continuation
        let analyzerStream: AsyncStream<AnalyzerInput>
    }

    nonisolated private static func performHeavySetup(locale: Locale) async throws -> SetupResult {
        // 1. Build transcriber.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )

        // 2. Ensure language model is downloaded. No-op if installed.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        // 3. Audio session — off-main, safe to block.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setActive(true, options: [])

        // 4. Best format for this transcriber — the format
        // SpeechAnalyzer wants us to deliver (e.g., 16 kHz Int16 for
        // speech). NOT the format the mic hardware produces.
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        // 5. Engine + tap.
        //
        // CRITICAL: `installTap(format:)` REQUIRES the input node's
        // native hardware format (e.g., 48 kHz Float32 on iPhone 17
        // Pro). Passing any other format throws
        // `com.apple.coreaudio.avfaudio` and crashes the app — this
        // exception is uncaught, so the whole app terminates silently
        // and looks like a freeze. Previous version passed the
        // analyzer's preferred format here, which is wrong.
        //
        // The fix: tap with the input's native format, then convert
        // each buffer to the analyzer's format via AVAudioConverter
        // before yielding to the stream.
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Build converter if analyzer needs a different format.
        let converter: AVAudioConverter?
        if let analyzerFormat, analyzerFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: analyzerFormat)
        } else {
            converter = nil
        }

        // 6. Audio buffer stream. Emits AnalyzerInput.
        //
        // CoreAudio reuses the same buffer pool for installTap
        // callbacks, so we must copy (or convert to a new buffer)
        // before yielding. The AVAudioConverter path below always
        // produces a fresh destination buffer, so it doubles as a copy.
        let (analyzerStream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let outputFormat = analyzerFormat ?? inputFormat

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            if let converter {
                // Resample/reformat to analyzer's preferred format.
                // Output buffer capacity: proportional to input frames
                // scaled by sample-rate ratio. Use a safe upper bound.
                let ratio = outputFormat.sampleRate / inputFormat.sampleRate
                let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio * 1.1) + 32
                guard let out = AVAudioPCMBuffer(
                    pcmFormat: outputFormat,
                    frameCapacity: capacity
                ) else { return }

                var error: NSError?
                var consumed = false
                let status = converter.convert(to: out, error: &error) { _, inputStatus in
                    if consumed {
                        inputStatus.pointee = .noDataNow
                        return nil
                    }
                    consumed = true
                    inputStatus.pointee = .haveData
                    return buffer
                }

                guard status != .error, error == nil else { return }
                continuation.yield(AnalyzerInput(buffer: out))
            } else {
                // Formats match — just copy the buffer to detach it
                // from CoreAudio's recycled pool.
                guard let copy = AVAudioPCMBuffer(
                    pcmFormat: buffer.format,
                    frameCapacity: buffer.frameLength
                ) else { return }
                copy.frameLength = buffer.frameLength
                if let src = buffer.floatChannelData,
                   let dst = copy.floatChannelData {
                    let channels = Int(buffer.format.channelCount)
                    let frames = Int(buffer.frameLength)
                    for c in 0..<channels {
                        memcpy(dst[c], src[c], frames * MemoryLayout<Float>.size)
                    }
                } else if let src = buffer.int16ChannelData,
                          let dst = copy.int16ChannelData {
                    let channels = Int(buffer.format.channelCount)
                    let frames = Int(buffer.frameLength)
                    for c in 0..<channels {
                        memcpy(dst[c], src[c], frames * MemoryLayout<Int16>.size)
                    }
                }
                continuation.yield(AnalyzerInput(buffer: copy))
            }
        }

        engine.prepare()
        try engine.start()

        // 7. SpeechAnalyzer consumes the AnalyzerInput stream directly.
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        return SetupResult(
            engine: engine,
            transcriber: transcriber,
            analyzer: analyzer,
            continuation: continuation,
            analyzerStream: analyzerStream
        )
    }

    /// Clean up resources that were created but not wired into the
    /// instance (e.g., start() was abandoned mid-setup).
    nonisolated private static func tearDownResources(_ r: SetupResult) {
        r.continuation.finish()
        r.engine.inputNode.removeTap(onBus: 0)
        if r.engine.isRunning { r.engine.stop() }
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Result handling (main actor)

    private func handleTranscriberResult(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters)
        if result.isFinal {
            // Guard: if we already transitioned past .listening (e.g.,
            // fallback finalize or cancel beat us to it), drop this
            // result. Prevents double-state-flip and stale-session
            // results overwriting current state. (Multi-source finding.)
            guard case .listening = state else { return }
            // Cancel any pending fallback-finalize timer so it can't
            // re-commit with stale partial text.
            finalizeTask?.cancel(); finalizeTask = nil
            lastFinalText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            tearDownSync()
            state = .committed(final: lastFinalText)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, case .committed = self.state else { return }
                self.state = .idle
            }
        } else {
            // Partial result: update the private partial text but
            // do NOT touch @Published state. That's the entire point
            // of the simplification — avoid re-rendering ChatView on
            // every partial. Reset the silence timer so auto-commit
            // moves forward as new words arrive.
            guard case .listening = state else { return }
            currentPartial = text
            resetSilenceTimer()
        }
    }

    private func fallbackFinalize(with partial: String) async {
        // If a real isFinal result already arrived and transitioned
        // us to .committed (or anywhere else), don't overwrite.
        // Prevents double-state-flip when isFinal lands during the
        // 700ms fallback sleep.
        guard case .listening = state else { return }
        let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        lastFinalText = trimmed
        tearDownSync()
        state = .committed(final: trimmed)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self, case .committed = self.state else { return }
            self.state = .idle
        }
    }

    // MARK: - Silence timer (main actor)

    private func resetSilenceTimer() {
        silenceTask?.cancel()
        // Progress ticker removed — it was mutating @Published state
        // 30 times per second, saturating the main actor with ChatView
        // re-renders. Nothing in the current edge-glow UI reads the
        // silence progress, so we just keep the auto-commit timer.
        silenceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.silenceTotal))
            if Task.isCancelled { return }
            self.commit()
        }
    }

    // MARK: - Teardown

    private func tearDownSync() {
        isFinalizing = false
        currentPartial = ""
        silenceTask?.cancel(); silenceTask = nil
        finalizeTask?.cancel(); finalizeTask = nil

        audioContinuation?.finish()
        audioContinuation = nil

        resultsTask?.cancel(); resultsTask = nil
        analyzeTask?.cancel(); analyzeTask = nil

        if tapInstalled {
            engine?.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if let engine, engine.isRunning {
            engine.stop()
        }
        engine = nil

        if audioSessionActive {
            try? AVAudioSession.sharedInstance()
                .setActive(false, options: .notifyOthersOnDeactivation)
            audioSessionActive = false
        }

        analyzer = nil
        transcriber = nil
    }
}
