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

@MainActor
final class Transcriber: ObservableObject {
    @Published private(set) var isListening: Bool = false
    @Published private(set) var transcript: String = ""
    @Published private(set) var error: TranscriberError?

    enum TranscriberError: Error, LocalizedError {
        case notAuthorized
        case onDeviceRecognitionUnsupported
        case audioEngineFailed(Error)

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Dictation needs Microphone and Speech Recognition permission. Open Settings to enable."
            case .onDeviceRecognitionUnsupported:
                return "Dictation isn't available for your language on this device. Please type instead."
            case .audioEngineFailed(let underlying):
                return "Audio input failed: \(underlying.localizedDescription)"
            }
        }
    }

    private var recognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    init(locale: Locale = .current) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
    }

    func start() async {
        // Guard against double-start. If the user double-taps the mic button
        // fast, the second call would create a second AVAudioEngine and
        // orphan the first one (with its audio tap still running).
        guard !isListening else { return }

        // Request permissions first. Both mic and speech recognition are required.
        let speechStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status) }
        }
        let micAllowed = await AVAudioApplication.requestRecordPermission()
        guard speechStatus == .authorized, micAllowed else {
            self.error = .notAuthorized
            return
        }
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            self.error = .onDeviceRecognitionUnsupported
            return
        }

        do {
            // Activate a record-oriented audio session so the input node
            // actually gets audio. Without this, AVAudioEngine.inputNode
            // can return silent/empty buffers if the default session is in
            // a playback-only category (or if music is playing via another
            // app). Duck other audio so the user isn't competing with music.
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            try startAudioEngine(with: recognizer)
            self.isListening = true
            self.transcript = ""
            self.error = nil
        } catch {
            self.error = .audioEngineFailed(error)
            // If the engine failed partway, make sure the session is released.
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func stop() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        audioEngine = nil
        isListening = false
        // Release the audio session so other apps' audio (music, calls) can
        // resume normal routing. Failing here isn't user-visible.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Clears the last error so UI alerts can dismiss and reset state.
    func clearError() {
        self.error = nil
    }

    private func startAudioEngine(with recognizer: SFSpeechRecognizer) throws {
        let engine = AVAudioEngine()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true  // P5: stay on-device

        let inputNode = engine.inputNode
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputNode.outputFormat(forBus: 0)) { buffer, _ in
            req.append(buffer)
        }
        engine.prepare()
        try engine.start()

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
}
