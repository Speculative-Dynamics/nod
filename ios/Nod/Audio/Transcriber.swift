// Transcriber.swift
// Wraps SFSpeechRecognizer for optional on-device speech-to-text input.
//
// The user types by default. The mic icon triggers dictation; the transcript
// fills the text input field for the user to review and edit before sending.
// This preserves precision for technical vocabulary (names, acronyms, etc.)
// where on-device STT is weakest.
//
// Uses `requiresOnDeviceRecognition = true` so audio never leaves the phone.
// If the user's locale doesn't support on-device recognition, the start
// attempt fails with onDeviceRecognitionUnsupported rather than falling back
// to Apple's server STT — never silently compromises the privacy promise.

import Foundation
import Speech
import AVFoundation
import OSLog

private let log = Logger(subsystem: "app.usenod.nod", category: "Transcriber")

@MainActor
final class Transcriber: ObservableObject {
    @Published private(set) var isListening: Bool = false
    @Published private(set) var transcript: String = ""
    @Published private(set) var error: TranscriberError?

    enum TranscriberError: Error, LocalizedError {
        case notAuthorized
        case onDeviceRecognitionUnsupported
        case audioEngineFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Dictation needs Microphone and Speech Recognition permission. Open Settings to enable."
            case .onDeviceRecognitionUnsupported:
                return "Dictation isn't available for your language on this device. Please type instead."
            case .audioEngineFailed(let reason):
                return "Audio input failed: \(reason)"
            }
        }
    }

    private var recognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    init(locale: Locale = .current) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
        log.info("Transcriber init for locale \(locale.identifier)")
    }

    // MARK: - Start / stop

    func start() async {
        log.info("Transcriber.start() called")
        guard !isListening else {
            log.info("already listening, ignoring")
            return
        }

        // 1. Speech Recognition authorization
        let speechStatus = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status) }
        }
        log.info("speech auth status: \(speechStatus.rawValue)")
        guard speechStatus == .authorized else {
            self.error = .notAuthorized
            return
        }

        // 2. Microphone authorization
        let micAllowed = await AVAudioApplication.requestRecordPermission()
        log.info("mic allowed: \(micAllowed)")
        guard micAllowed else {
            self.error = .notAuthorized
            return
        }

        // 3. Recognizer availability
        guard let recognizer else {
            log.error("no recognizer for current locale")
            self.error = .onDeviceRecognitionUnsupported
            return
        }
        guard recognizer.isAvailable else {
            log.error("recognizer unavailable")
            self.error = .onDeviceRecognitionUnsupported
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            log.error("recognizer doesn't support on-device")
            self.error = .onDeviceRecognitionUnsupported
            return
        }

        // 4. Audio session — kept simple. `.record` mode, defaults. No
        //    option flags that might require extra entitlements on iOS 26.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
            log.info("audio session active")
        } catch {
            log.error("audio session setup failed: \(error.localizedDescription)")
            self.error = .audioEngineFailed("session setup: \(error.localizedDescription)")
            return
        }

        // 5. Audio engine + tap + recognition task. Wrapped so any
        //    thrown Swift error becomes a user-visible message. Obj-C
        //    exceptions from installTap (invalid format) still crash —
        //    the format validation below is specifically to prevent that.
        do {
            try startAudioEngine(with: recognizer)
            self.isListening = true
            self.transcript = ""
            self.error = nil
            log.info("dictation started successfully")
        } catch let e as TranscriberError {
            log.error("engine start failed: \(e.localizedDescription ?? "")")
            self.error = e
            releaseAudioSession()
        } catch {
            log.error("engine start failed: \(error.localizedDescription)")
            self.error = .audioEngineFailed(error.localizedDescription)
            releaseAudioSession()
        }
    }

    func stop() {
        log.info("Transcriber.stop() called")
        if let engine = audioEngine {
            engine.stop()
            // Only remove the tap if one was successfully installed. Calling
            // removeTap on a bus with no tap is a no-op but logs a warning.
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        audioEngine = nil
        isListening = false
        releaseAudioSession()
    }

    /// Clears the last error so UI alerts can dismiss and reset state.
    func clearError() {
        self.error = nil
    }

    // MARK: - Internals

    private func startAudioEngine(with recognizer: SFSpeechRecognizer) throws {
        let engine = AVAudioEngine()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = true

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        log.info("input format: sampleRate=\(format.sampleRate), channels=\(format.channelCount)")

        // Critical guard: installTap crashes with an Obj-C exception
        // (unrecoverable) if the format has 0 channels or 0 sample rate.
        // This can happen when the audio session isn't active or some
        // other process holds the mic.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw TranscriberError.audioEngineFailed(
                "Microphone returned invalid format. Another app may be using the mic."
            )
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            req.append(buffer)
        }
        log.info("tap installed")

        engine.prepare()
        try engine.start()
        log.info("engine started")

        let task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                if let result {
                    self?.transcript = result.bestTranscription.formattedString
                }
                if error != nil || result?.isFinal == true {
                    self?.stop()
                }
            }
        }

        self.audioEngine = engine
        self.request = req
        self.recognitionTask = task
    }

    private func releaseAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            log.error("audio session deactivate failed: \(error.localizedDescription)")
        }
    }
}
