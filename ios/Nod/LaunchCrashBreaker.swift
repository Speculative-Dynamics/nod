// LaunchCrashBreaker.swift
// Safe-mode-on-crash for Nod's on-device LLM loop.
//
// The problem this solves:
//   Loading a 2.6-3.0 GB MLX model into memory during cold launch
//   can push the process past iOS's launch-time memory budget —
//   especially after a prior session grew the KV cache. Jetsam kills
//   the app. The engine preference is persisted, so the next launch
//   tries the same thing and gets killed again. The user ends up with
//   an app that won't open.
//
// The fix (Paperback / Chrome-style safe mode):
//   1. Bump a "launchInProgress" flag at the very top of NodApp.init.
//   2. Clear it after ChatView has been mounted long enough that any
//      launch-time memory spike is behind us (~15s).
//   3. On subsequent launches, if the flag is still set AND consecutive-
//      crashes >= 1, we know the previous launch didn't complete.
//      Force EnginePreferenceStore.current = .apple before anything
//      else allocates. Surface the fallback in the UI so the user
//      knows why they're on Apple Intelligence.
//
// Second signal — memory warnings during chat:
//   UIApplication.didReceiveMemoryWarningNotification is iOS telling
//   us "you're about to be killed." If we're mid-session on an MLX
//   engine when that fires, flip to .apple immediately. The engine
//   swap drops the MLXEngineClient actor, which releases its
//   ModelContainer (and the 2.6 GB of weights) via ARC.

import Foundation
import SwiftUI

@MainActor
final class LaunchCrashBreaker: ObservableObject {

    // MARK: - Keys

    private enum Keys {
        /// Set to true at the top of NodApp.init; cleared when ChatView
        /// reports it has been mounted long enough to consider the launch
        /// "settled." If this key is still true at the start of the next
        /// launch, the previous launch didn't complete.
        static let launchInProgress = "LaunchCrashBreaker.launchInProgress"

        /// How many launches in a row didn't reach "settled." One is
        /// enough to trigger the fallback — we'd rather overcorrect than
        /// leave the user in a loop.
        static let consecutiveCrashes = "LaunchCrashBreaker.consecutiveCrashes"
    }

    /// Triggering signal for the banner / escalation path. Nil when the
    /// UI should be silent.
    enum FallbackReason: String, Sendable {
        /// Detected at app startup: prior launch didn't settle.
        case launchCrashLoop
        /// First memory warning on an MLX engine this window. ChatView
        /// observes this reason and tells EngineHolder to release the
        /// active MLX container — we try to recover without leaving the
        /// user's chosen engine.
        case memoryPressureFirstStrike
        /// A second memory warning fired within `strikeWindow` of the
        /// first. We escalate: flip preference to Apple so the next
        /// engine swap drops the weights for real, and surface it.
        case memoryPressure
    }

    static let shared = LaunchCrashBreaker()

    /// Drives the one-shot banner in ChatView. Cleared by dismissBanner().
    @Published private(set) var didAutoFallback: Bool = false
    @Published private(set) var fallbackReason: FallbackReason?

    private let defaults = UserDefaults.standard

    /// Timestamp of the last memory warning we acted on. Drives the
    /// two-strike escalation: second warning inside `strikeWindow`
    /// means the release-and-retry strategy didn't save us, so we
    /// fall all the way back to Apple.
    private var lastWarningAt: Date?

    /// Window within which a second warning counts as "the first
    /// recovery didn't work." 60 s is long enough to give the released
    /// container a chance to stabilise, short enough that unrelated
    /// later pressure doesn't trigger a phantom escalation.
    private let strikeWindow: TimeInterval = 60

    private init() {}

    // MARK: - Launch lifecycle

    /// Call at the VERY top of NodApp.init, before anything else allocates.
    /// Decides whether to force .apple for this run based on whether the
    /// previous launch reached a settled state.
    ///
    /// Returns the engine preference the app should use for this run. If
    /// this is a normal launch, the caller's stored preference is honored.
    /// If we detected a crash loop, .apple is forced and persisted so
    /// EngineHolder sees it consistently.
    func markLaunchStarted() {
        let previousLaunchInProgress = defaults.bool(forKey: Keys.launchInProgress)
        var crashes = defaults.integer(forKey: Keys.consecutiveCrashes)

        if previousLaunchInProgress {
            // The previous launch set launchInProgress = true but never
            // cleared it. Either we crashed, or iOS killed us mid-load.
            crashes += 1
            defaults.set(crashes, forKey: Keys.consecutiveCrashes)
        }

        // Mark THIS launch in progress. Synchronous write — we want this
        // on disk before any model-loading code runs. UserDefaults writes
        // are atomic and the sync call here is cheap (tiny key).
        defaults.set(true, forKey: Keys.launchInProgress)

        // One strike and we protect the user. If the stored preference
        // is already .apple, the fallback is a no-op; we still set
        // didAutoFallback = false because there's nothing to tell them.
        if crashes >= 1 {
            let currentPref = EnginePreferenceStore.current
            if currentPref != .apple {
                EnginePreferenceStore.current = .apple
                didAutoFallback = true
                fallbackReason = .launchCrashLoop
            }
        }
    }

    /// Call after ChatView has been on screen long enough to consider the
    /// launch "past the danger zone" — ~15 seconds is enough to clear
    /// iOS's tight launch-time memory budget and any eager-prepare work.
    func markLaunchSettled() {
        defaults.set(false, forKey: Keys.launchInProgress)
        defaults.set(0, forKey: Keys.consecutiveCrashes)
    }

    // MARK: - Runtime signal

    /// Called when UIApplication.didReceiveMemoryWarningNotification fires.
    /// Two-strike escalation:
    ///   • First warning on an MLX engine → emit `.memoryPressureFirstStrike`.
    ///     ChatView observes this and tells EngineHolder to release the
    ///     active MLX container, freeing ~2.6 GB of weights. Preference
    ///     stays on MLX; the next send transparently re-prepares.
    ///   • Second warning within `strikeWindow` → the release didn't save
    ///     us, so flip preference to Apple for real and surface it.
    ///
    /// AFM path: noop. Nothing to release.
    func handleMemoryWarning() {
        let currentPref = EnginePreferenceStore.current
        guard currentPref.mlxSpec != nil else { return }

        let now = Date()
        let withinStrikeWindow: Bool = {
            guard let last = lastWarningAt else { return false }
            return now.timeIntervalSince(last) < strikeWindow
        }()
        lastWarningAt = now

        if withinStrikeWindow {
            // Second strike: the lighter-touch release didn't help.
            // Escalate all the way to Apple Intelligence.
            EnginePreferenceStore.current = .apple
            didAutoFallback = true
            fallbackReason = .memoryPressure
        } else {
            // First strike: keep their chosen engine, just drop the
            // weights. The emitted reason is what ChatView listens to
            // in order to route the actual release call through
            // EngineHolder — keeps this singleton from needing a
            // direct engine reference.
            didAutoFallback = true
            fallbackReason = .memoryPressureFirstStrike
        }
    }

    // MARK: - UI

    /// Call when the user acknowledges the banner. Clears the signal so
    /// the next launch (if clean) shows no banner.
    func dismissBanner() {
        didAutoFallback = false
        fallbackReason = nil
    }

    /// Copy shown in the banner. Depends on which signal triggered the
    /// fallback — memory-pressure during chat reads differently than
    /// a boot-crash-loop-at-launch.
    var bannerText: String {
        switch fallbackReason {
        case .memoryPressureFirstStrike:
            return "Freed up memory — Nod will reload on the next message."
        case .memoryPressure:
            return "Switched to Apple Intelligence — Nod ran low on memory. You can switch back from the menu."
        case .launchCrashLoop:
            return "Switched to Apple Intelligence — the last session didn't finish cleanly. You can switch back from the menu."
        case .none:
            return ""
        }
    }
}
