// EngineHolder.swift
// Observable owner of the current inference engine. Bridges the
// UserDefaults-backed EnginePreference into SwiftUI so ChatView and
// SidebarView both see the same live engine and react when it changes.
//
// Why a holder instead of plain @State in ChatView: the summarizer
// closure captured by ConversationStore needs to always return the
// CURRENT engine, even after the user switches. Capturing the holder
// gives us that — the closure reads `holder.engine` every time it fires.
//
// Also mirrors MLXEngineClient's internal state into a @Published
// `mlxEngineLoadState` so the download progress bar updates reactively
// without polling.
//
// Switching engines drops the old instance. For any MLX engine:
//   - Switching TO an MLX engine: kicks off prepare() eagerly so the
//     download starts at switch time, not on first message send.
//   - Switching AWAY from an MLX engine: calls cancelDownload() so the
//     in-flight download cancels with resume data persisted to the
//     outgoing spec's per-engine .resume.data file. Coming back to
//     that engine later resumes from the same byte.

import Foundation
import SwiftUI

@MainActor
final class EngineHolder: ObservableObject {

    @Published private(set) var preference: EnginePreference
    @Published private(set) var engine: (any ListeningEngine)?

    /// Mirrored from the active MLX engine's state stream.
    /// `.notLoaded` when the current engine is AFM (or none). Drives
    /// the download progress UI in ChatView.
    @Published private(set) var mlxEngineLoadState: MLXEngineClient.State = .notLoaded

    private var mlxObservationTask: Task<Void, Never>?
    private var eagerPrepareTask: Task<Void, Never>?

    init() {
        let stored = EnginePreferenceStore.current
        // If the stored preference isn't available on THIS device (e.g.
        // user restored a backup from an 8GB phone to a 4GB one), fall
        // back to Apple Intelligence rather than trying to download and
        // OOM at runtime. Persist the coerced value so the sidebar
        // reflects reality.
        let effective = stored.isAvailable ? stored : .apple
        if effective != stored {
            EnginePreferenceStore.current = effective
        }
        self.preference = effective
        self.engine = Self.makeEngine(for: effective)
        attachMLXObserverIfNeeded()
    }

    /// Switch to a different engine. No-op if already on that preference.
    /// For MLX→MLX switches, the outgoing engine's in-flight download is
    /// cancelled with resume data persisted to its per-spec resume file,
    /// so the user can come back to it later without re-downloading.
    func setPreference(_ newValue: EnginePreference) {
        guard newValue != preference else { return }

        // Tear down anything tied to the outgoing engine.
        tearDownCurrentMLXIfAny()

        EnginePreferenceStore.current = newValue
        preference = newValue
        engine = Self.makeEngine(for: newValue)
        mlxEngineLoadState = .notLoaded

        attachMLXObserverIfNeeded()
    }

    /// Retry the load after a failure. Exposed so the readiness bar
    /// can offer a "Try again" button without leaking the client type.
    func retryMLXLoad() {
        guard let client = engine as? MLXEngineClient else { return }
        eagerPrepareTask?.cancel()
        eagerPrepareTask = Task { try? await client.prepare() }
    }

    /// Pause the active MLX download. Transitions state to .paused(metrics)
    /// and persists resume data so a later Resume tap picks up where we
    /// left off. Called by ChatView's Cancel confirmation handler.
    func cancelMLXDownload() {
        guard let client = engine as? MLXEngineClient else { return }
        eagerPrepareTask?.cancel()
        eagerPrepareTask = nil
        Task { await client.cancelDownload() }
    }

    /// Resume a paused download. Called by ChatView's Resume button.
    func resumeMLXDownload() {
        guard let client = engine as? MLXEngineClient else { return }
        eagerPrepareTask?.cancel()
        eagerPrepareTask = Task { try? await client.resumeDownload() }
    }

    /// Delete a non-active, downloaded MLX model from disk to reclaim
    /// space. Called by the sidebar's per-row Delete affordance. No-op
    /// for the active model (UI blocks that via `canDelete(pref:)`) and
    /// for AFM (has nothing to delete).
    ///
    /// Also wipes the resume-data file at `<modelDir>/.resume.data` so
    /// a future download starts clean rather than trying to resume from
    /// a now-orphaned blob.
    func deleteDownloadedModel(for pref: EnginePreference) {
        guard pref != preference,
              let spec = pref.mlxSpec else { return }
        spec.deleteDownloadedFiles()
        // objectWillChange so sidebar rows re-read isFullyDownloaded.
        objectWillChange.send()
    }

    /// Whether the sidebar should show a Delete affordance for this row.
    /// True only for inactive MLX engines with files actually on disk.
    func canDelete(_ pref: EnginePreference) -> Bool {
        guard pref != preference,
              let spec = pref.mlxSpec else { return false }
        return spec.isFullyDownloaded || spec.hasPartialDownload
    }

    /// One-shot cellular override for THIS download attempt. Does not flip
    /// the persistent `MLXR2BackgroundSession.shared.cellularAllowed`.
    /// Called by the "Use cellular this time" link on the
    /// Waiting-for-Wi-Fi card.
    func useCellularThisTime() {
        guard let client = engine as? MLXEngineClient else { return }
        Task { await client.useCellularThisTime() }
    }

    /// The persistent cellular preference (binding-friendly).
    /// Flipping this to true un-gates the download immediately if we
    /// were sitting in .waitingForWifi.
    var cellularAllowed: Bool {
        get { MLXR2BackgroundSession.shared.cellularAllowed }
        set {
            MLXR2BackgroundSession.shared.cellularAllowed = newValue
            // Nudge the session to re-evaluate its gate. The path
            // monitor's pathUpdateHandler won't re-fire unless the path
            // changes, so a preference flip mid-wait needs an explicit kick.
            if newValue, case .waitingForWifi = mlxEngineLoadState {
                useCellularThisTime()
            }
            objectWillChange.send()
        }
    }

    // MARK: - Private

    private static func makeEngine(for pref: EnginePreference) -> (any ListeningEngine)? {
        switch pref {
        case .apple:
            return try? FoundationModelsClient()
        case .qwen3, .qwen35, .gemma4:
            guard let spec = pref.mlxSpec else { return nil }
            return try? MLXEngineClient(spec: spec)
        }
    }

    /// If the current engine is an MLX engine, start observing its state
    /// stream AND kick off the download eagerly. Safe to call on any
    /// transition to an MLX preference.
    private func attachMLXObserverIfNeeded() {
        guard let client = engine as? MLXEngineClient else { return }

        // Observe state changes and mirror them into @Published.
        // Task inherits MainActor from the enclosing @MainActor class in
        // Swift 6, so we can assign to @Published directly without hopping.
        mlxObservationTask = Task { [weak self] in
            let stream = await client.makeStateStream()
            for await newState in stream {
                guard let self else { return }
                self.mlxEngineLoadState = newState
            }
        }

        // Eager prepare so the download starts at switch time, not on
        // first message send. Errors surface through the state stream
        // as .failed, which the UI already handles.
        eagerPrepareTask = Task { try? await client.prepare() }
    }

    private func tearDownCurrentMLXIfAny() {
        eagerPrepareTask?.cancel()
        eagerPrepareTask = nil
        mlxObservationTask?.cancel()
        mlxObservationTask = nil

        if let outgoing = engine as? MLXEngineClient {
            // Fire-and-forget cancellation. `cancelDownload()` calls
            // the session's `cancelAndPersistResume`, which produces
            // URLSession resume data before stopping the in-flight
            // download task and writes it to the outgoing spec's
            // per-engine `.resume.data` file. Switching back to this
            // engine later picks up from the same byte (per eng-review
            // decision #2).
            //
            // We don't reset container/state on the outgoing — it's
            // about to be released by ARC (we're reassigning `engine`
            // to the new one just below), so the MLX container gets
            // cleaned up naturally.
            Task { await outgoing.cancelDownload() }
        }
    }
}
