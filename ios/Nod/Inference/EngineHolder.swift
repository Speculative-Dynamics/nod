// EngineHolder.swift
// Observable owner of the current inference engine. Bridges the
// UserDefaults-backed EnginePreference into SwiftUI so ChatView and
// SidebarView both see the same live engine and can react when it changes.
//
// Why a holder instead of a plain @State in ChatView: the summarizer
// closure captured by ConversationStore needs to always return the
// CURRENT engine, even after the user switches. Capturing the holder
// gives us that — the closure reads `holder.engine` every time it fires.
//
// Also mirrors QwenClient's internal state into a @Published `qwenLoadState`
// so the download progress bar updates reactively without polling.
//
// Switching engines drops the old instance. For Qwen:
//   - Switching TO qwen: kicks off prepare() eagerly so the download
//     starts at switch time, not on first message send.
//   - Switching AWAY from qwen: calls cancelLoading() so an in-flight
//     download stops and doesn't leak bandwidth.

import Foundation
import SwiftUI

@MainActor
final class EngineHolder: ObservableObject {

    @Published private(set) var preference: EnginePreference
    @Published private(set) var engine: (any ListeningEngine)?

    /// Mirrored from QwenClient's state stream. .notLoaded when the
    /// current engine isn't Qwen. Drives the download progress UI.
    @Published private(set) var qwenLoadState: QwenClient.State = .notLoaded

    private var qwenObservationTask: Task<Void, Never>?
    private var eagerPrepareTask: Task<Void, Never>?

    init() {
        let stored = EnginePreferenceStore.current
        // If the stored preference isn't available on THIS device (e.g.
        // user restored a backup from an 8GB phone to a 4GB one), fall
        // back to Apple Intelligence rather than trying to download 2.3GB
        // and OOM at runtime. Persist the coerced value so the sidebar
        // reflects reality.
        let effective = stored.isAvailable ? stored : .apple
        if effective != stored {
            EnginePreferenceStore.current = effective
        }
        self.preference = effective
        self.engine = Self.makeEngine(for: effective)
        attachQwenObserverIfNeeded()
    }

    /// Switch to a different engine. No-op if already on that preference.
    func setPreference(_ newValue: EnginePreference) {
        guard newValue != preference else { return }

        // Tear down anything tied to the outgoing engine.
        tearDownCurrentQwenIfAny()

        EnginePreferenceStore.current = newValue
        preference = newValue
        engine = Self.makeEngine(for: newValue)
        qwenLoadState = .notLoaded

        attachQwenObserverIfNeeded()
    }

    /// Retry the Qwen load after a failure. Exposed so the readiness bar
    /// can offer a "Try again" button without leaking the client type.
    func retryQwenLoad() {
        guard preference == .qwen, let client = engine as? QwenClient else { return }
        eagerPrepareTask?.cancel()
        eagerPrepareTask = Task { try? await client.prepare() }
    }

    // MARK: - Private

    private static func makeEngine(for pref: EnginePreference) -> (any ListeningEngine)? {
        switch pref {
        case .apple: return try? FoundationModelsClient()
        case .qwen:  return try? QwenClient()
        }
    }

    /// If the current engine is Qwen, start observing its state stream
    /// AND kick off the download eagerly. Safe to call on any transition
    /// to a .qwen preference.
    private func attachQwenObserverIfNeeded() {
        guard preference == .qwen, let client = engine as? QwenClient else { return }

        // Observe state changes and mirror them into @Published.
        // Task inherits MainActor from the enclosing @MainActor class in
        // Swift 6, so we can assign to @Published directly without hopping.
        qwenObservationTask = Task { [weak self] in
            let stream = await client.makeStateStream()
            for await newState in stream {
                guard let self else { return }
                self.qwenLoadState = newState
            }
        }

        // Eager prepare so the download starts at switch time, not on
        // first message send. Errors surface through the state stream
        // as .failed, which the UI already handles.
        eagerPrepareTask = Task { try? await client.prepare() }
    }

    private func tearDownCurrentQwenIfAny() {
        eagerPrepareTask?.cancel()
        eagerPrepareTask = nil
        qwenObservationTask?.cancel()
        qwenObservationTask = nil

        if let outgoing = engine as? QwenClient {
            // Fire-and-forget cancellation: URLSession inside HubApi
            // should respect Task cancellation at its suspension points.
            Task { await outgoing.cancelLoading() }
        }
    }
}
