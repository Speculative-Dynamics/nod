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
import UIKit

/// Fine-grained observer of the MLX engine's load state. Lives as a
/// standalone ObservableObject so SwiftUI views that want the 5-Hz
/// download progress stream observe IT directly, without routing through
/// EngineHolder. That split is the whole point: during a 5-minute
/// download, `state` changes ~1500 times. If this were a `@Published`
/// on EngineHolder, every view observing EngineHolder (notably the
/// whole of ChatView) would re-evaluate its body 1500 times, which
/// single-handedly drops us below 120 fps. By keeping the flood in a
/// separate object, only `MLXReadinessBar` re-renders on progress.
///
/// EngineHolder still emits COARSE transitions (isModelReady flips on
/// ready/not-ready only) for callers that need reactive readiness —
/// e.g. the send button's enabled state.
@MainActor
final class DownloadStateObserver: ObservableObject {
    @Published var state: MLXEngineClient.State = .notLoaded
}

@MainActor
final class EngineHolder: ObservableObject {

    @Published private(set) var preference: EnginePreference
    @Published private(set) var engine: (any ListeningEngine)?

    /// Coarse-grained "can the user send a message" signal. Flips only
    /// on ready/not-ready transitions, so views that gate on readiness
    /// (the send button, the input bar's placeholder) re-render at most
    /// a few times per session rather than 1500 times per download.
    @Published private(set) var isModelReady: Bool = false

    /// Fine-grained download state — 5 Hz during an active download.
    /// Declared `let` (not `@Published`) so mutations to its inner
    /// `@Published state` DON'T propagate up through EngineHolder's
    /// own observers. Only views that explicitly observe this object
    /// (the readiness bar subview) re-render on progress ticks.
    let downloadObserver = DownloadStateObserver()

    /// Passthrough for non-reactive callers that just want to sample
    /// the current state. Reading this does NOT subscribe to changes.
    var mlxEngineLoadState: MLXEngineClient.State { downloadObserver.state }

    private var mlxObservationTask: Task<Void, Never>?
    private var eagerPrepareTask: Task<Void, Never>?

    /// Idle-unload timer. Fires `idleUnloadInterval` after the last user
    /// activity and drops the MLX ModelContainer, freeing ~2.3-3.0 GB.
    /// Re-started every time ChatView reports a send via `noteActivity()`.
    private var idleUnloadTask: Task<Void, Never>?

    /// How long after the last send we hold the weights in memory. Short
    /// enough that a user who puts the phone down doesn't leave 2.6 GB
    /// resident indefinitely; long enough that pausing to think mid-
    /// exchange doesn't trigger a reload.
    private let idleUnloadInterval: Duration = .seconds(10 * 60)

    /// Shorter timeout used when the app backgrounds. If the user comes
    /// back within a minute it's the same session; longer than that and
    /// we want the weights gone so iOS doesn't jetsam us while the app
    /// is suspended.
    private let backgroundUnloadDelay: Duration = .seconds(60)

    init() {
        let stored = EnginePreferenceStore.current
        // If the stored preference isn't available on THIS device (e.g.
        // user restored a backup from an 8GB phone to a 4GB one), fall
        // back. Priority order:
        //   1. Stored preference if still available
        //   2. Otherwise .apple (its UI handles the "AFM not available"
        //      onboarding and banner states — we do NOT auto-fallback
        //      to an MLX engine because that would kick off a silent
        //      2-3 GB download the user didn't consent to)
        //
        // Previously the fallback also auto-coerced stored to .apple
        // when MLX was unavailable. We keep that, but additionally:
        // when .apple isn't available either (iPhone 15 base, iPad
        // without M-series), we STILL keep preference at .apple. The
        // ChatView onboarding renders the pick-a-model card in that
        // case and the user makes the download decision explicitly.
        let effective = stored.isAvailable ? stored : .apple
        if effective != stored {
            EnginePreferenceStore.current = effective
        }
        self.preference = effective
        self.engine = Self.makeEngine(for: effective)
        // AFM is ready as soon as the client exists AND the runtime
        // check passes. MLX flips to ready only after the stream
        // observer sees `.ready`. The extra `canRunAFM` gate prevents
        // the send button from looking enabled on an iPhone 15 base
        // that can't actually generate.
        self.isModelReady = (effective.mlxSpec == nil) && DeviceCapability.canRunAFM
        // On cold launch we ONLY attach the state observer — we do NOT
        // eagerly load the 2-3 GB MLX model here. Loading during init
        // puts us inside iOS's tight launch-time memory budget, and a
        // prior session that grew the KV cache can push us over the
        // jetsam line before ChatView even renders. ChatView calls
        // `startEagerPrepareIfNeeded()` from a .task once the view has
        // mounted — by then we're past the launch danger zone.
        //
        // Mid-session engine switches (setPreference) still prepare
        // eagerly; the hazard is specifically cold-launch memory
        // pressure.
        attachMLXObserverIfNeeded(startEagerPrepare: false)
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
        downloadObserver.state = .notLoaded
        // AFM is ready only if the hardware + user settings actually
        // allow it. MLX needs a load either way. See the init comment
        // for why we don't auto-fallback when AFM isn't available.
        isModelReady = (preference.mlxSpec == nil) && DeviceCapability.canRunAFM

        // Mid-session switches should start the download/load right
        // away — the user just picked a new engine, latency would be
        // surprising. `attachMLXObserverIfNeeded` handles the MLX
        // state stream + MLX prepare. `startEagerPrepareIfNeeded` is
        // called as a belt-and-suspenders pass to cover the AFM case
        // (switching TO Apple Intelligence mid-session should warm the
        // model too). For MLX the eagerPrepareTask guard means this is
        // a no-op — the MLX prepare was already started inside
        // attachMLXObserverIfNeeded.
        attachMLXObserverIfNeeded(startEagerPrepare: true)
        startEagerPrepareIfNeeded()
    }

    /// Called by ChatView from a deferred `.task` once the view has
    /// mounted. Warms up whichever engine is active so the user's
    /// first send doesn't pay a cold-model-load cost.
    ///
    /// MLX: starts the download/load (hydrates the 2-3 GB weights).
    /// AFM: calls `prewarm()` to tell iOS to preload the on-device
    ///      model so the first `respond()` doesn't pay the 1-2s
    ///      model-load hit. This was a notable gap — MLX users got
    ///      eager prepare but AFM users hit the cold-load on their
    ///      first message, which reads as "the app is laggy" rather
    ///      than "the model loads on first send."
    ///
    /// Uses `Task.detached(priority: .utility)` instead of plain
    /// `Task { }`. Rationale: the default priority inherits from the
    /// caller (MainActor = `.userInitiated`), which puts model-load
    /// work on equal footing with splash animation + SwiftUI layout.
    /// On cold launch that's a visible contention: splash can stutter
    /// while weights load. Lowering to `.utility` tells iOS "this
    /// matters but NOT at the cost of UI." Main-thread animations win
    /// the scheduler. Warmup may take 10-20% longer but the UI stays
    /// perfectly smooth, which is the right trade for perceived feel.
    ///
    /// Idempotent: the `eagerPrepareTask` guard ensures we only warm
    /// once per session. On engine switch, `setPreference` tears this
    /// down and calls again.
    func startEagerPrepareIfNeeded() {
        guard eagerPrepareTask == nil else { return }
        if let client = engine as? MLXEngineClient {
            eagerPrepareTask = Task.detached(priority: .utility) {
                try? await client.prepare()
            }
        } else if let afm = engine as? FoundationModelsClient {
            eagerPrepareTask = Task.detached(priority: .utility) {
                await afm.prewarm()
            }
        }
    }

    /// ChatView calls this on every send. Resets the idle-unload timer
    /// so a user who's actively chatting never has their model yanked
    /// out from under them. The prior timer (if any) is cancelled and
    /// a fresh one armed.
    func noteActivity() {
        armIdleUnloadTimer(after: idleUnloadInterval)
    }

    /// ChatView calls this when the scene transitions to .background.
    /// Arms a shorter-fuse unload (60 s) so a backgrounded app doesn't
    /// keep 2-3 GB of weights resident indefinitely — iOS is aggressive
    /// about jetsam on suspended apps holding that much memory.
    /// Returning to foreground re-starts the eager prepare via ChatView's
    /// normal .task path.
    func noteBackgrounded() {
        armIdleUnloadTimer(after: backgroundUnloadDelay)
    }

    /// Coming back to foreground. Cancel any pending background unload —
    /// the user is actively here again.
    func noteForegrounded() {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
    }

    /// Drop the active MLX engine's ModelContainer right now, no timer.
    /// Called by the memory-warning escalation path in LaunchCrashBreaker
    /// when the crash breaker wants to free weights before falling back
    /// all the way to AFM. No-op on AFM (nothing to release).
    func releaseActiveMLXContainer() {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        eagerPrepareTask?.cancel()
        eagerPrepareTask = nil
        guard let client = engine as? MLXEngineClient else { return }
        Task { await client.releaseContainer() }
    }

    private func armIdleUnloadTimer(after delay: Duration) {
        idleUnloadTask?.cancel()
        // Only arm if we're actually on an MLX engine with something to
        // unload. AFM has nothing to reclaim.
        guard engine is MLXEngineClient else { return }
        idleUnloadTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.releaseActiveMLXContainer()
        }
    }

    /// Retry the load after a failure. Exposed so the readiness bar
    /// can offer a "Try again" button without leaking the client type.
    ///
    /// `.utility` priority mirrors the cold-launch + engine-switch
    /// paths. Same reasoning: model download/load shouldn't steal
    /// scheduler cycles from UI animations if the user is doing
    /// something else while waiting.
    func retryMLXLoad() {
        guard let client = engine as? MLXEngineClient else { return }
        eagerPrepareTask?.cancel()
        eagerPrepareTask = Task.detached(priority: .utility) {
            try? await client.prepare()
        }
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
    /// Uses `.utility` priority for the same reason as the other
    /// model-load paths — download work should not contend with UI.
    func resumeMLXDownload() {
        guard let client = engine as? MLXEngineClient else { return }
        eagerPrepareTask?.cancel()
        eagerPrepareTask = Task.detached(priority: .utility) {
            try? await client.resumeDownload()
        }
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
    /// stream. When `startEagerPrepare` is true, also kick off the
    /// download/load immediately. Cold launch passes `false` (ChatView
    /// triggers it later via `startEagerPrepareIfNeeded()`); mid-session
    /// switches pass `true` so the user doesn't wait until send-time.
    private func attachMLXObserverIfNeeded(startEagerPrepare: Bool) {
        guard let client = engine as? MLXEngineClient else { return }

        // Observe state changes and mirror them into @Published.
        // Task inherits MainActor from the enclosing @MainActor class in
        // Swift 6, so we can assign to @Published directly without hopping.
        mlxObservationTask = Task { [weak self] in
            let stream = await client.makeStateStream()
            for await newState in stream {
                guard let self else { return }
                // Fine-grained: route progress through the fine-grained
                // observer. Only views that explicitly @ObservedObject this
                // one re-render at 5 Hz.
                self.downloadObserver.state = newState

                // Coarse-grained: only flip the @Published `isModelReady`
                // when readiness actually changes. SwiftUI views observing
                // EngineHolder re-render on THIS, not on every progress
                // tick.
                let nowReady: Bool = {
                    if case .ready = newState { return true } else { return false }
                }()
                if self.isModelReady != nowReady {
                    self.isModelReady = nowReady
                }

                // Idle-timer side effect: keep the screen awake while bytes
                // are actively moving or MLX is loading. Was previously
                // driven by `.onChange(of: engineHolder.mlxEngineLoadState)`
                // in ChatView, which (because mlxEngineLoadState was
                // @Published on EngineHolder) invalidated ChatView's body
                // at the full 10 Hz download rate. Moving it here keeps
                // the behavior while letting the UI stay at 120 fps.
                switch newState {
                case .downloading, .loading:
                    UIApplication.shared.isIdleTimerDisabled = true
                case .ready, .failed, .notLoaded,
                     .waitingForNetwork, .waitingForWifi, .paused:
                    UIApplication.shared.isIdleTimerDisabled = false
                }
            }
        }

        if startEagerPrepare {
            // Errors surface through the state stream as .failed, which
            // the UI already handles. `.utility` priority mirrors the
            // cold-launch path in `startEagerPrepareIfNeeded` — UI work
            // wins the scheduler, MLX load takes slightly longer but
            // the user feels a smooth switch.
            eagerPrepareTask = Task.detached(priority: .utility) {
                try? await client.prepare()
            }
        }
    }

    private func tearDownCurrentMLXIfAny() {
        eagerPrepareTask?.cancel()
        eagerPrepareTask = nil
        mlxObservationTask?.cancel()
        mlxObservationTask = nil
        idleUnloadTask?.cancel()
        idleUnloadTask = nil

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
