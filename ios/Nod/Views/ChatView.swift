// ChatView.swift
// The one screen in Phase 1. Chat message list + text input + send button.
//
// Layout:
//   ┌─────────────────────────────────────┐
//   │ 🟠                                  │  nav bar: MiniNodFace (leading),
//   │                                     │           no title text
//   ├─────────────────────────────────────┤
//   │    AI bubble (left-aligned)         │
//   │           User bubble (right)       │  scrolling message list
//   │    AI bubble                        │
//   │                                     │
//   ├─────────────────────────────────────┤
//   │ ┌──────────────────────┐  ↑         │  input bar: text + send
//   │ │ Type what's on…      │            │  (dictation = keyboard's built-in
//   │ └──────────────────────┘            │   mic button — no custom code)
//   └─────────────────────────────────────┘

import SwiftUI
import UIKit
import os

struct ChatView: View {

    @StateObject private var store: ConversationStore
    /// EntityStore is observed separately so SwiftUI picks up changes to
    /// its `@Published pendingDisambiguations`. It's actually owned by
    /// `store` (same instance); exposing it here lets the view render
    /// the disambiguation banner reactively.
    @StateObject private var entityStore: EntityStore
    @ObservedObject private var crashBreaker = LaunchCrashBreaker.shared
    // `personalization` is intentionally NOT observed here. PersonalizationStore
    // fires `@Published current` on every sidebar picker tick AND every
    // keystroke in the 400-char free-form text field. Observing it would
    // invalidate ChatView's body on every keystroke a user types in settings.
    // ChatView only reads the preference once per send (see `respond(to:)`),
    // so we read on-demand via `PersonalizationStore.shared.current.*` at
    // that point instead. SidebarView still observes — its pickers bind to
    // the store via Binding(get:set:).
    @Environment(\.scenePhase) private var scenePhase
    /// Passed into SidebarView (sheet) as the explicit color scheme.
    /// ChatView's `@Environment(\.colorScheme)` reflects the app's
    /// current scheme (set by NodApp's `.preferredColorScheme`) and
    /// updates reactively when NodApp resolves `.system` to nil and
    /// the app re-inherits from iOS. A sheet's own @Environment
    /// doesn't track that nil transition reliably, so we pass the
    /// value down as an explicit prop.
    @Environment(\.colorScheme) private var hostColorScheme
    @State private var inputText: String = ""
    @State private var nodTrigger: Int = 0
    @State private var isInferring: Bool = false
    /// Handle to the in-flight inference task. Held so the stop button
    /// can cancel mid-stream. Cancellation propagates through the stream
    /// continuation's `onTermination` → the engine's producer task,
    /// which actually stops the GPU (for MLX) instead of just stopping
    /// the UI from reading.
    @State private var inferenceTask: Task<Void, Never>? = nil
    /// Buffer that the streaming loop writes to on every chunk (cheap),
    /// and that a separate 30 Hz flush tick reads to call
    /// `store.updateLastAssistantMessageInMemory(with:)`. Separating the
    /// two means MLX can emit 80 tok/s without triggering 80 main-actor
    /// mutations + 80 WAL writes per second — one smooth UI update
    /// cadence regardless of token rate.
    @State private var pendingSnapshot: String = ""
    /// The flush tick. Lives for the duration of a stream. Cancelled
    /// when stream completes or user taps stop.
    @State private var flushTask: Task<Void, Never>? = nil
    @State private var showingSidebar: Bool = false
    /// Controls the "Pause download?" alert triggered by Cancel on the
    /// downloading card. Splitting it into its own state avoids races
    /// where a fast-fingered user could double-tap.
    @State private var showingCancelDownloadAlert: Bool = false
    // The ID of the bottom-most fully-visible message. Bound to the
    // ScrollView via .scrollPosition. When user scrolls manually, this
    // updates; we use it to decide whether auto-scroll should follow new
    // messages or leave the user reading history undisturbed.
    /// Drives scroll position via Apple's iOS 18+ ScrollPosition API.
    /// Initialized with `.bottom` edge so first layout pins to the
    /// latest message. Paired with `.scrollTargetLayout()` on the
    /// LazyVStack (required for ScrollPosition to know content
    /// bounds) and programmatic scrolls via
    /// `scrollPosition.scrollTo(edge: .bottom)`.
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    /// Shows a floating "↓ New message" pill at the bottom-right when a
    /// new assistant reply arrives while the user is scrolled up reading
    /// history. Standard Discord/Slack/Telegram pattern — without it,
    /// new replies slide in silently off-screen.
    @State private var hasNewMessageBelow: Bool = false
    /// Memoized chat-row derivation. `Self.chatRows(from:)` is O(N) with
    /// Calendar day checks per message; running it fresh on every body
    /// evaluation (of which there are many triggered by scroll, focus,
    /// personalization reads) wastes real CPU at 100+ message histories.
    /// Rebuild only when the message set actually changes — keyed below
    /// via `.task(id:)` on the count + last-id composite.
    @State private var cachedRows: [ChatView.ChatRow] = []

    // MARK: - Dictation state

    /// Owns the on-device speech recognition pipeline (AVAudioEngine +
    /// SFSpeechRecognizer). Lives on ChatView so the mic indicator
    /// teardown survives overlay dismissal and scenePhase changes.
    @StateObject private var dictationRecognizer = DictationRecognizer()

    // Dictation runs inline now — no overlay, no fullScreenCover.
    // The mic button toggles recording directly via
    // `dictationRecognizer.start()` / `.commit()`. While recording,
    // `isRecording` (computed from `dictationRecognizer.state`)
    // drives the mic-becomes-stop icon swap and the edge glow.

    /// Set each time dictation commits a non-empty transcript. Watched
    /// by the input field's post-commit pulse animation so the user's
    /// eye catches misheard words before they tap send. Never
    /// persisted — pure UI signal.
    @State private var committedAt: Date?

    /// True when the mic button has been tapped at least once in this
    /// session. Until then, render a subtle .symbolEffect(.pulse) on
    /// the mic icon to hint discoverability.
    @AppStorage("dictation.hasTappedMic") private var hasTappedMic: Bool = false

    /// Two-mode right-side action button. Mic has its own dedicated
    /// button (see `micButton` in the input bar) so the send arrow
    /// stays put and never "disappears" into a mic icon when the
    /// input is empty. Clearer mental model: send-arrow means send,
    /// always; tapping the separate mic icon means talk instead.
    private enum SendButtonRole: Equatable {
        case send  // text present, not streaming → send
        case stop  // streaming → cancel

        static func from(isInferring: Bool) -> SendButtonRole {
            isInferring ? .stop : .send
        }

        var iconName: String {
            switch self {
            case .send: return "arrow.up"
            case .stop: return "stop.fill"
            }
        }

        var a11yLabel: String {
            switch self {
            case .send: return "Send message"
            case .stop: return "Stop response"
            }
        }

        var a11yHint: String {
            switch self {
            case .send: return ""
            case .stop: return "Stops the current reply; partial text is preserved"
            }
        }
    }

    /// True when the scroll view's visible area reaches the bottom of
    /// the content. Measured via `.onScrollGeometryChange` below, so
    /// it reflects REAL layout (content offset + container height vs
    /// content height), not SwiftUI's `.scrollPosition` binding.
    ///
    /// That distinction matters: the binding is unreliable during
    /// animations, keyboard transitions, and especially when content
    /// doesn't fill the viewport (short conversations). It could
    /// report an adjacent message's id or `nil` at arbitrary moments,
    /// which caused the jump-to-bottom pill to misfire. Geometry is
    /// immune to all of that — it just asks "is the visible bottom at
    /// or past the content bottom?"
    ///
    /// Every "is the user at the bottom?" decision below reads from
    /// this value. Starts at true (fresh chat, empty content, no
    /// scrolling possible = user is implicitly at bottom).
    @State private var isAtBottom: Bool = true

    /// True when the AFM-unavailable onboarding card should take over
    /// the screen in place of the normal empty state. This happens when
    /// the user's stored engine preference is Apple Intelligence but
    /// this device can't actually run AFM, AND there's no existing
    /// chat history (the history case is handled by a persistent
    /// banner above messageList instead).
    ///
    /// The onboarding is a full-screen takeover: while it's showing,
    /// the input bar is hidden (there's no model to send to yet) so
    /// the surface doesn't look like a half-loaded chat. This property
    /// is also the single source of truth for that hide.
    private var isShowingAFMOnboarding: Bool {
        engineHolder.preference == .apple
            && !DeviceCapability.canRunAFM
            && store.messages.isEmpty
    }
    @FocusState private var inputFocused: Bool

    // EngineHolder owns the live engine. Holding it as @StateObject means
    // sidebar-driven engine switches propagate here automatically. The
    // same engine instance it hands out serves BOTH listening responses
    // (respond) AND compression summaries (summarize).
    @StateObject private var engineHolder: EngineHolder

    init() {
        let holder = EngineHolder()
        self._engineHolder = StateObject(wrappedValue: holder)

        // Open the SQLite DB. If it fails (typically because the app was
        // killed mid-write and the file is left inconsistent — a very real
        // crash-on-open failure mode), quarantine the bad file and try a
        // fresh one. Losing the conversation history is strictly better
        // than "app never opens again, user must delete and reinstall."
        let db = Self.openOrQuarantineDatabase()

        // EntityStore is created first so ConversationStore can receive
        // a reference. Both are wrapped in their own StateObjects so
        // SwiftUI observes them independently — ChatView renders the
        // disambiguation banner off EntityStore's queue while the rest
        // of the chat runs off ConversationStore.
        let entities = EntityStore(database: db)
        self._entityStore = StateObject(wrappedValue: entities)

        // Capture the holder (not a specific engine) so compression always
        // uses whichever engine is current when it fires — even if the user
        // switched between append and the compression task starting.
        // Same rationale for the entity fallback: extraction prefers AFM,
        // but falls back to the active listening engine if AFM refuses
        // or is unavailable, and the "active" engine can change.
        self._store = StateObject(wrappedValue: ConversationStore(
            database: db,
            entityStore: entities,
            summarizer: { [holder] in holder.engine },
            entityFallbackProvider: { [holder] in holder.engine }
        ))
    }

    private static let storageLog = Logger(subsystem: "app.usenod.nod", category: "storage")

    /// Attempt to open the DB. On failure, move the broken file aside with
    /// a timestamped suffix and retry once. Keeping (not deleting) the bad
    /// file preserves it for post-mortem diagnostics while unblocking the
    /// app. If the retry also fails, fall through to fatalError — at that
    /// point the filesystem itself is likely unusable.
    private static func openOrQuarantineDatabase() -> MessageDatabase {
        if let db = try? MessageDatabase() {
            return db
        }
        let brokenURL = MessageDatabase.fileURL
        let quarantineURL = brokenURL
            .deletingLastPathComponent()
            .appending(path: "nod-conversation.broken-\(Int(Date().timeIntervalSince1970)).sqlite")
        storageLog.error("DB open failed; moving to \(quarantineURL.lastPathComponent, privacy: .public) and retrying")
        try? FileManager.default.moveItem(at: brokenURL, to: quarantineURL)
        // SQLite may also leave WAL and SHM sidecars. Move those too so the
        // retry sees a clean slate.
        for sidecar in ["-wal", "-shm"] {
            let src = URL(fileURLWithPath: brokenURL.path + sidecar)
            let dst = URL(fileURLWithPath: quarantineURL.path + sidecar)
            try? FileManager.default.moveItem(at: src, to: dst)
        }
        do {
            return try MessageDatabase()
        } catch {
            fatalError("Nod: could not open conversation database after quarantine: \(error)")
        }
    }

    var body: some View {
        // Root-level split: the AFM-unavailable onboarding is a full-
        // screen takeover, NOT a view stuffed inside the chat UI. That
        // means no nav bar (no small mascot to open the sidebar), no
        // input bar, no chat scaffolding at all — just the pick-a-
        // model surface. Rationale: the user on this branch hasn't
        // chosen to be in a chat yet. Rendering the chat chrome
        // behind it makes it look half-loaded and gives them a
        // sidebar affordance that would just loop back to this same
        // screen (since AFM is the selected-but-unusable engine).
        //
        // The mid-conversation banner (restore-migration case, where
        // messages ARE non-empty) still renders inside the normal
        // NavigationStack below — that user DOES have a chat to see.
        if isShowingAFMOnboarding {
            AFMUnavailableOnboarding(
                afmStatus: DeviceCapability.afmStatus,
                canRunMLX: DeviceCapability.canRunMLX4BClass,
                onPickModel: { pref in
                    engineHolder.setPreference(pref)
                }
            )
            .background(Color(.systemBackground))
            // Status bar stays visible (default). Input accessory
            // would also stay if the onboarding had a TextField, but
            // it doesn't — so no keyboard surfaces from this view.
        } else {
            normalChat
        }
    }

    private var normalChat: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // One-shot banner when the breaker flipped us to Apple
                // Intelligence — either because iOS issued a memory
                // warning during a chat, or because the previous launch
                // didn't complete. User can dismiss; never auto-shown
                // after a clean launch.
                if crashBreaker.didAutoFallback {
                    fallbackBanner
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Entity disambiguation prompts. Entity extraction can
                // produce a new name that fuzzy-matches an existing
                // entity (e.g. "Mark" and we already know "M, manager").
                // Rather than guess, we ask the user. One banner per
                // pending prompt, queued in order.
                if let pending = entityStore.pendingDisambiguations.first {
                    disambiguationBanner(for: pending)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .id(pending.id)
                }

                // Persistent "AFM not available" banner. Only shown when
                // the user's active preference is Apple Intelligence,
                // AFM can't run on this device, AND there's existing
                // history (messages non-empty). Fresh empty state with
                // no AFM is handled by `afmOnboarding` below, not a
                // banner. The banner shape is the restore-migration
                // case: user had history on an AFM-capable phone,
                // restored onto a weaker one.
                if engineHolder.preference == .apple,
                   !DeviceCapability.canRunAFM,
                   !store.messages.isEmpty {
                    AFMUnavailableBanner()
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Note: when `isShowingAFMOnboarding` is true, this whole
                // NavigationStack is replaced at the root of `body` by
                // the full-screen onboarding takeover. So here we only
                // handle the normal chat states: empty → EmptyStateView,
                // populated → messageList.
                if store.messages.isEmpty {
                    EmptyStateView()
                } else {
                    messageList
                        // Tail gap OUTSIDE the scroll view. See the
                        // long comment inside messageList's body for
                        // the rationale — short version: putting the
                        // gap here instead of as LazyVStack bottom
                        // padding makes programmatic scroll-to-bottom
                        // and manual-scroll-to-end behave identically.
                        // The gap is always visible between the last
                        // message and whatever's below (NodAnimation,
                        // MLXReadinessBar, or inputBar).
                        .padding(.bottom, 16)
                }

                if isInferring {
                    // While Nod is thinking, the eyes do a left-right-blink
                    // loop so the user feels an active presence rather than
                    // staring at static eyes.
                    NodAnimation(trigger: nodTrigger, isThinking: true)
                        .padding(.bottom, 8)
                        .transition(.opacity)
                }

                // MLX engines (Qwen 3, Qwen 3.5, Gemma 4) all have a
                // pre-send readiness step (download + load). AFM is
                // ready as soon as it exists.
                //
                // The bar is its own subview that observes `engineHolder.
                // downloadObserver` directly — NOT `engineHolder`. That
                // split is the perf fix: during a 5 min download, progress
                // changes ~1500 times. If ChatView observed those changes
                // (as it used to, via `@Published mlxEngineLoadState` on
                // EngineHolder), the entire body would re-evaluate 1500
                // times, murdering 120 fps. Now only this subview reacts
                // to the 5 Hz flood; ChatView stays at rest.
                if engineHolder.preference.mlxSpec != nil {
                    MLXReadinessBar(
                        observer: engineHolder.downloadObserver,
                        modelDisplayName: activeModelDisplayName,
                        totalBytes: activeModelTotalBytes,
                        onRetry: { engineHolder.retryMLXLoad() },
                        onResume: { engineHolder.resumeMLXDownload() },
                        onUseCellular: { engineHolder.useCellularThisTime() },
                        onRequestCancel: { showingCancelDownloadAlert = true }
                    )
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }

                inputBar
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // The mascot opens the sidebar. The tricky part is
                    // stripping iOS 26's Liquid Glass treatment. That
                    // treatment is applied at the TOOLBAR ITEM layer —
                    // NOT the inner Button — which is why
                    // `.buttonStyle(.plain)` and bare-view/onTapGesture
                    // approaches both still showed the capsule chrome.
                    //
                    // Two things together fix it:
                    //   1. `.sharedBackgroundVisibility(.hidden)` on the
                    //      ToolbarItem strips the Liquid Glass capsule.
                    //      (iOS 26+ API.)
                    //   2. A zero-state ButtonStyle that ignores
                    //      configuration.isPressed kills the press-tint
                    //      flash — the orange "yellow" on tap.
                    Button {
                        showingSidebar = true
                    } label: {
                        MiniNodFace()
                    }
                    .buttonStyle(MascotButtonStyle())
                    .accessibilityLabel("Open menu")
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .sheet(isPresented: $showingSidebar) {
                SidebarView(
                    store: store,
                    engineHolder: engineHolder,
                    entityStore: entityStore,
                    hostColorScheme: hostColorScheme
                ) {
                    // User tapped "Start fresh" and confirmed. Reset any
                    // local in-flight state that isn't owned by the store.
                    isInferring = false
                    // Warning haptic confirms the destructive action landed.
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                }
            }
            // Dictation state observer.
            //
            // The recording UI is just: the mic button morphs to a
            // stop icon AND an orange edge glow appears around the
            // app while recording. No modal, no fullscreen view,
            // no mascot. Siri-style ambient presence.
            //
            // When the recognizer transitions to .committed, we
            // capture the transcript, append it to the input field,
            // and raise the keyboard so the user can edit before
            // sending. Missed-state fallback on .idle: if SwiftUI
            // coalesces .committed→.idle and we see only .idle with
            // non-empty lastFinalText, deliver it anyway.
            .onChange(of: dictationRecognizer.state) { oldValue, newValue in
                handleDictationStateChange(from: oldValue, to: newValue)
            }
            // Siri-style edge glow. When dictation is active, a soft
            // orange halo traces the phone's outer edge. Fades in/out
            // over 300ms. Single view, single animation driver via
            // `.opacity(isRecording ? 1 : 0)` + `.animation` — no
            // repeatForever, no overlapping transactions.
            .overlay(alignment: .center) {
                recordingEdgeGlow
                    .opacity(isRecording ? 1 : 0)
                    .animation(.easeInOut(duration: 0.3), value: isRecording)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
            }
            // "Pause download?" confirmation. Default action is "Keep
            // downloading" (safer on accidental tap). "Pause" is .cancel
            // role (not .destructive) because Pause is genuinely
            // reversible — resume data is persisted and the user can
            // resume whenever. Destructive-red would miscommunicate.
            .alert("Pause download?", isPresented: $showingCancelDownloadAlert) {
                Button("Keep downloading", role: nil) { }
                Button("Pause", role: .cancel) {
                    engineHolder.cancelMLXDownload()
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                }
            } message: {
                Text("Your progress is saved — you can resume anytime.")
            }
            // Note: the `.onChange(of: mlxEngineLoadState)` that drove
            // `UIApplication.shared.isIdleTimerDisabled` used to live here,
            // but that observation counted as a ChatView-body dependency on
            // the 5 Hz download stream — the root cause of the 120 fps drop
            // during downloads. The idle-timer toggling now happens inside
            // EngineHolder's stream observer task, off the SwiftUI graph.
            .onDisappear {
                // Belt-and-suspenders: if the view goes away mid-download
                // (shouldn't happen — ChatView is the root — but defensive),
                // release the idle lock so we don't drain battery forever.
                UIApplication.shared.isIdleTimerDisabled = false
            }
            // Cold-launch pipeline. Three things happen in parallel so
            // the splash window (~1.9 s) covers all of them:
            //
            //   1. Engine warmup (AFM prewarm or MLX prepare) fires
            //      immediately. Runs on .utility priority inside
            //      EngineHolder so UI work wins scheduler contention.
            //   2. Both stores hydrate off-main (SQLite fetch in a
            //      Task.detached, state assigned back on MainActor).
            //      async let runs them concurrently. On a typical chat
            //      both complete in 50-300 ms — well inside the splash.
            //   3. Crash-breaker markLaunchSettled ticks at 15 s. If
            //      we got this far the launch wasn't the kind the
            //      breaker needs to protect against.
            //
            // Removed the old 500 ms pre-prepare sleep: with hydrate
            // moved off-main, there's no main-thread work to let
            // "settle" before kicking off warmup. Earlier warmup start
            // = warmer model by the time user sends.
            //
            // .task cancels automatically if the view disappears.
            .task {
                engineHolder.startEagerPrepareIfNeeded()

                async let messagesHydrate: Void = store.hydrate()
                async let entitiesHydrate: Void = entityStore.hydrate()
                _ = await (messagesHydrate, entitiesHydrate)

                try? await Task.sleep(for: .seconds(15))
                LaunchCrashBreaker.shared.markLaunchSettled()
            }
            // Idle-unload on background. If the user sends the app to
            // background, we don't need to keep 2-3 GB of weights
            // resident — iOS is aggressive about jetsam on suspended
            // apps holding that much memory. noteBackgrounded() arms a
            // 60s fuse; coming back to foreground cancels it and the
            // eager-prepare path re-loads as needed.
            //
            // Backgrounding also counts as a "settled" signal for the
            // crash breaker — if we got this far we clearly survived
            // launch. Without this, a user who backgrounds within the
            // 15 s settle window above would leave launchInProgress=true
            // and trigger a false-positive crash detection on the next
            // cold launch.
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .background:
                    engineHolder.noteBackgrounded()
                    LaunchCrashBreaker.shared.markLaunchSettled()
                case .active:
                    engineHolder.noteForegrounded()
                    // If the container was unloaded while we were away,
                    // start reloading now so the first send isn't slow.
                    engineHolder.startEagerPrepareIfNeeded()
                    // Nudge the scroll anchor to the last message so when
                    // the user comes back they land at the latest turn,
                    // not wherever they scrolled to before leaving. This
                    // is the same intent as the `.onAppear` scroll on
                    // messageList, but SwiftUI doesn't re-fire onAppear
                    // on a background→foreground transition. Matching
                    // iMessage / WhatsApp behaviour.
                    // Scroll to bottom on resume via the scrollPosition
                    // binding's API. `scrollTo(edge:)` is preferred
                    // over `scrollTo(id:)` because it doesn't require
                    // the target row to be materialized in the
                    // LazyVStack.
                    scrollPosition.scrollTo(edge: .bottom)
                case .inactive:
                    break
                @unknown default:
                    break
                }
            }
            // Chat-row cache rebuild — at ChatView root (not on
            // messageList) so it fires even when messageList is NOT in
            // the tree. Specifically, after Start Fresh the view swaps
            // to EmptyStateView; if we only invalidated from within
            // messageList, the cache would keep stale deleted rows and
            // briefly flash them when a new message triggers remount.
            // Rebuilding here means cachedRows is always consistent with
            // store.messages.count regardless of which branch is showing.
            .onChange(of: store.messages.count) { _, _ in
                cachedRows = Self.chatRows(from: store.messages)
            }
            // ALSO rebuild on text change of the last message. Critical
            // for the assistant-reply flow: `respond(to:)` appends an
            // empty placeholder (count change → cache rebuild), then
            // `replaceLastAssistantMessage(with: reply)` mutates text
            // in place (count UNCHANGED). Without this second trigger,
            // `cachedRows` keeps the empty-text snapshot of the
            // placeholder; the reply doesn't render until the NEXT
            // count-changing event (usually the user's next send),
            // which is exactly the "my replies show up one send late"
            // bug the memoization introduced.
            .onChange(of: store.messages.last?.text) { _, _ in
                cachedRows = Self.chatRows(from: store.messages)
            }
            // Two-strike memory-warning handler. LaunchCrashBreaker runs
            // the state machine (strike 1 → emit firstStrike, strike 2 →
            // flip to Apple). We observe the reason here and actually
            // route the MLX-container release, since the breaker
            // singleton doesn't hold an engine reference.
            .onChange(of: crashBreaker.fallbackReason) { _, newReason in
                if newReason == .memoryPressureFirstStrike {
                    engineHolder.releaseActiveMLXContainer()
                }
            }
            .animation(.easeInOut(duration: 0.25), value: crashBreaker.didAutoFallback)
            // Swipe-down-to-dismiss-keyboard gesture. Swipe-up-to-open
            // was removed — it triggered on normal upward scrolling
            // through chat history, which made keyboard open
            // unexpectedly. WhatsApp / iMessage don't do it, and neither
            // do we. Keyboard dismiss via downward swipe stays because
            // it's intentional and matches iOS conventions (plus
            // `.scrollDismissesKeyboard(.interactively)` on the
            // scroll view handles the in-scroll drag down).
            //
            // Uses simultaneousGesture so it doesn't steal events from
            // the scroll view's own drag.
            .simultaneousGesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        let dy = value.translation.height
                        let dx = abs(value.translation.width)
                        // Only react to primarily-vertical swipes
                        guard abs(dy) > dx else { return }
                        if dy > 40 {
                            inputFocused = false    // swipe down → dismiss keyboard
                        }
                        // Intentionally no swipe-up branch.
                    }
            )
            // iPad keyboard shortcuts. On iPhone these are harmless — no
            // hardware keyboard means they never fire. Cmd+Return sends
            // (sendMessage self-gates on sendEnabled). Cmd+K focuses the
            // input so you can start typing without tapping. Kept always
            // enabled: disabling Cmd+K based on focus state is backwards —
            // that's precisely when you'd want the shortcut.
            .background(
                ZStack {
                    Button("") { sendMessage() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .hidden()
                    Button("") { inputFocused = true }
                        .keyboardShortcut("k", modifiers: .command)
                        .hidden()
                }
            )
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Spacing: 0 at the VStack level; each bubble contributes its
                // own top padding based on whether the message above it was
                // from the same speaker. Grouping same-speaker messages tight
                // (4 pt) and separating cross-speaker turns wider (14 pt)
                // reads like iMessage — blocks of thought from one voice
                // feel unified, the shift to the other voice has room to
                // breathe. Nod-blink rows get a little extra breathing room
                // since the eyes are visually weighty.
                //
                // Between messages we interleave "breakpoints" — a date
                // separator when the calendar day changes ("Today",
                // "Yesterday", "Mon, Mar 15") and a time label when the
                // same-day gap between messages exceeds 10 minutes
                // ("2:30 PM"). iMessage does the same thing; without
                // them, a multi-day conversation reads as one endless
                // wall of text with no temporal structure.
                // Read the memoized cache (rebuilt on count changes below).
                // Fallback-compute on first render: `.onAppear` fires AFTER
                // the first body pass, so on cold launch with history the
                // cache is empty but messages exist — without this one-off
                // compute the user would see a blank list for one frame.
                // Steady-state body evals (scroll, focus) use the cache.
                let rows: [ChatRow] = cachedRows.isEmpty && !store.messages.isEmpty
                    ? Self.chatRows(from: store.messages)
                    : cachedRows
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        let prevRow = index > 0 ? rows[index - 1] : nil
                        switch row {
                        case .breakpoint(_, let label, let isDate):
                            BreakpointView(label: label, isDate: isDate)
                                // Horizontal padding is applied PER ROW
                                // instead of on the LazyVStack because
                                // LazyVStack + `.scrollTargetLayout()`
                                // + external `.padding` breaks the
                                // padding on first layout (content
                                // lands flush against the leading
                                // edge until any user interaction
                                // triggers a relayout). Per-row padding
                                // sidesteps that interaction entirely.
                                .padding(.horizontal, 12)
                        case .message(let msg):
                            let isLastAssistant = msg.role == .assistant
                                && store.messages.last?.id == msg.id
                            // Regenerate is deliberately context-menu-only.
                            // An inline retry button next to every reply
                            // breaks the "being heard" feel of the chat
                            // surface — it turns Nod's voice into an LLM
                            // output to be iterated on. Long-press the
                            // bubble to find it; power users will, casual
                            // users won't reach for it, and that's the
                            // right balance for this product.
                            MessageBubble(
                                message: msg,
                                isLast: isLastAssistant,
                                onRegenerate: isLastAssistant && canRegenerate(msg)
                                    ? { regenerate() }
                                    : nil
                            )
                            .id(msg.id)
                            .padding(.top, Self.topPadding(for: msg,
                                                           prevRow: prevRow))
                            .padding(.horizontal, 12)  // per-row, see note above
                        }
                    }
                }
                // `.scrollTargetLayout()` DIRECTLY on the LazyVStack
                // with NO `.padding` modifier between them. Required
                // for `.scrollPosition($scrollPosition)` with an
                // edge-based initial value to resolve "bottom" against
                // the LazyVStack's bounds on first layout. Horizontal
                // padding is pushed to individual rows above so this
                // modifier chain stays clean.
                .scrollTargetLayout()
                .padding(.top, 12)
                // NOTE: no .padding(.bottom) here. The tail gap between
                // the last message and the input bar is applied to the
                // ScrollView's outer frame instead (see
                // `.padding(.bottom, 16)` further down). Reason:
                // programmatic `proxy.scrollTo(id, anchor: .bottom)`
                // aligns the target id's bottom edge with the
                // VIEWPORT's bottom, NOT the scroll content's bottom.
                // If the tail gap lives INSIDE the scroll content as
                // bottom padding, programmatic scroll-to-bottom hides
                // it (it sits just below the viewport edge), while
                // manual-scroll-to-end shows it. That mismatch is what
                // produced the "last message touches keyboard on
                // auto-scroll but has a gap on manual-scroll" bug.
                // Moving the gap outside the scroll view makes it
                // always visually present, scroll-method-agnostic.
            }
            // Interactive keyboard dismiss: dragging down on messages pulls
            // the keyboard down with the finger, iOS-native feel.
            .scrollDismissesKeyboard(.interactively)
            // Binds scroll position to our ScrollPosition state.
            // Initialized with `.bottom` edge (see @State declaration)
            // so first layout pins to the latest message. This
            // combination — `.scrollTargetLayout()` on LazyVStack +
            // `.scrollPosition($scrollPosition)` + `ScrollPosition(edge: .bottom)`
            // initial value — is what actually makes the scroll land
            // at the bottom on cold launch.
            .scrollPosition($scrollPosition)
            // Real-geometry "at bottom" detector. iOS 18+ API; app
            // targets iOS 26 so always available. Fires on every scroll
            // delta and on content-size changes. We collapse the
            // geometry to a single Bool via the `for:` projection, so
            // the `action` closure only fires when the Bool transitions
            // (not on every sub-pixel scroll) — that's the right
            // granularity for flipping UI state.
            //
            // 40pt tolerance absorbs the 16pt bottom padding inside
            // the LazyVStack, sub-pixel drift, and safe-area shifts
            // during keyboard transitions.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let visibleBottom = geometry.contentOffset.y
                    + geometry.containerSize.height
                    - geometry.contentInsets.bottom
                let contentBottom = geometry.contentSize.height
                return visibleBottom >= contentBottom - 40
            } action: { _, newAtBottom in
                isAtBottom = newAtBottom
                // When we settle back at the bottom, the jump-to-bottom
                // pill is no longer meaningful — clear it. Covers:
                // user manually scrolled down, content grew to fit,
                // user tapped the pill (which scrolls to bottom).
                if newAtBottom && hasNewMessageBelow {
                    hasNewMessageBelow = false
                }
            }
            .onChange(of: store.messages.count) { oldCount, newCount in
                guard newCount > 0 else { return }
                let msgs = store.messages
                let newLastId = msgs.last?.id

                // Follow the new message if the user is at the bottom,
                // or if they JUST sent (user send = strong signal they
                // want to participate in the current flow). `isAtBottom`
                // reflects the layout BEFORE the new row was inserted —
                // so if the user could see the last bubble when they
                // sent, we follow them to the new one.
                let userJustSent = newCount > oldCount
                    && msgs.last?.role == .user
                if (isAtBottom || userJustSent), let newLastId {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(newLastId, anchor: .bottom)
                    }
                } else if newCount > oldCount,
                          msgs.last?.role == .assistant,
                          !(msgs.last?.text.isEmpty ?? true) {
                    // User was scrolled up AND a fresh assistant message
                    // arrived with non-empty text (skip placeholder).
                    hasNewMessageBelow = true
                }
            }
            // Raise the pill flag when the last assistant message's
            // text goes from empty to non-empty while user is scrolled
            // up — catches the placeholder-to-reply fill-in case
            // (count doesn't change, so the handler above won't fire).
            .onChange(of: store.messages.last?.text) { oldText, newText in
                guard let last = store.messages.last,
                      last.role == .assistant,
                      (oldText?.isEmpty ?? true),
                      let newText, !newText.isEmpty,
                      !isAtBottom
                else { return }
                hasNewMessageBelow = true
            }
            // When the in-flight assistant message's text fills in,
            // also follow to bottom if the user was at the bottom.
            // Count doesn't change on replaceLastAssistantMessage, so
            // we need a separate trigger from count-onChange.
            .onChange(of: store.messages.last?.text) { _, _ in
                guard let newLastId = store.messages.last?.id,
                      isAtBottom
                else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(newLastId, anchor: .bottom)
                }
            }
            // Keyboard-open → scroll to bottom. Standard chat-app behavior:
            // when the user taps the input, they want to compose the NEXT
            // message, not stay wherever they were reading. Without this,
            // the input field pops up and the latest message is hidden
            // under the keyboard.
            .onChange(of: inputFocused) { _, focused in
                guard focused, let lastId = store.messages.last?.id else { return }
                // Slight delay so our scroll animates alongside the
                // keyboard, not before it. iOS's keyboard animation is
                // ~0.25s; firing our scroll with easeOut(0.3) after a
                // 50ms delay lets the safe-area shift settle first, then
                // we scroll the now-visible bottom into view.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
            // On first render (cold launch with existing history, or
            // re-entering after being away from the tab), land at the
            // bottom. SwiftUI's default is to scroll-top; with a long
            // history, users would see their oldest messages first and
            // have to scroll to find today's. That's the opposite of
            // what every chat app does.
            .onAppear {
                // Initial chat-row cache population. Synchronous here so
                // the very first render has the full row set — critical
                // because the scrollTo(lastId) below depends on the row
                // with that id actually existing in the list.
                cachedRows = Self.chatRows(from: store.messages)
                // Note: initial scroll-to-bottom on cold launch is now
                // handled by `ScrollPosition(edge: .bottom)` at the
                // `@State` declaration. The proxy.scrollTo fallback
                // below covers any edge case where the content size
                // changes after the initial layout (e.g., lazy rows
                // finishing materialization).
                if let lastId = store.messages.last?.id {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            }
            // Jump-to-bottom pill. Floats at the bottom-right corner of
            // the message list when a new assistant reply arrives while
            // the user is scrolled up reading history. Tap scrolls to
            // bottom and clears the flag. Discord / Slack / Telegram
            // all do this; without it, new replies land off-screen with
            // no indicator.
            .overlay(alignment: .bottomTrailing) {
                if hasNewMessageBelow {
                    Button {
                        if let lastId = store.messages.last?.id {
                            withAnimation(.easeOut(duration: 0.25)) {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            }
                            hasNewMessageBelow = false
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down")
                                .font(.caption.weight(.bold))
                            Text("New message")
                                .font(.caption.weight(.medium))
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color("NodAccent"))
                        .clipShape(Capsule())
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 16)
                    .padding(.bottom, 12)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("Jump to new message")
                }
            }
            .animation(.easeOut(duration: 0.2), value: hasNewMessageBelow)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            // Dedicated mic button, LEFT of the text field. Always
            // visible when not streaming (hidden during inference so
            // you can't talk over Nod thinking). Having mic as its
            // own button keeps the send arrow always present — no
            // disappearing send-becomes-mic swap that confused users
            // about where their "send" went.
            if !isInferring && !dictationRecognizer.isUnavailableForSession {
                micButton
            }

            // Text field with a post-commit underline pulse that
            // briefly flashes in NodAccent when a dictation commit
            // lands. Catches the user's eye so they notice misheard
            // words (a trust break on a venting app) before tapping
            // send. `committedAt` is the trigger; the overlay modifier
            // drives opacity 0→1→0 over ~1.5s.
            TextField("Type what's on your mind…", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(alignment: .bottom) {
                    if let committedAt {
                        PostCommitPulse(trigger: committedAt)
                            .allowsHitTesting(false)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
                .focused($inputFocused)
                .accessibilityLabel("Message")
                // No .submitLabel(.send)/.onSubmit here: with axis: .vertical
                // and lineLimit(1...5), Return inserts a newline (iMessage
                // behavior) and onSubmit never fires. A "send" label would
                // lie. Hardware keyboards get Cmd+Return via the shortcut
                // button in .background above.

            // Two-state right-side action button: send / stop.
            //   - Streaming → stop.fill, gray, tap cancels inference
            //   - Otherwise → arrow.up, NodAccent, tap sends
            // `.contentTransition(.symbolEffect(.replace.downUp))`
            // morphs the icon smoothly; fill animates via `.animation`
            // on the role. Mic is a separate button above — this one
            // never becomes a mic.
            let role = SendButtonRole.from(isInferring: isInferring)
            Button {
                handleSendButtonTap(role: role)
            } label: {
                ZStack {
                    Circle()
                        .fill(sendButtonFill(for: role))
                        .frame(width: 32, height: 32)
                    Image(systemName: role.iconName)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(sendButtonIconColor(for: role))
                        .contentTransition(.symbolEffect(.replace.downUp))
                }
                .animation(.easeInOut(duration: 0.15), value: role)
            }
            .disabled(isSendButtonDisabled(for: role))
            .accessibilityLabel(role.a11yLabel)
            .accessibilityHint(role.a11yHint)
        }
    }

    /// True when we're actively capturing voice. Used to morph the
    /// mic button into a stop button and to show the edge glow.
    private var isRecording: Bool {
        switch dictationRecognizer.state {
        case .listening, .requestingPermission:
            return true
        default:
            return false
        }
    }

    /// Dedicated mic button (left of the text field). Two-state:
    ///   - Not recording: mic icon, tap → `recognizer.start()`
    ///   - Recording:     stop icon, tap → `recognizer.commit()`
    ///     transcript lands in the input field via the state observer
    ///     on recognizer.state == .committed.
    private var micButton: some View {
        Button {
            hasTappedMic = true
            if isRecording {
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                dictationRecognizer.commit()
            } else {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                Task { await dictationRecognizer.start() }
            }
        } label: {
            Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isRecording ? .black : Color("NodAccent"))
                .frame(width: 32, height: 32)
                .background(
                    Circle().fill(
                        isRecording ? Color("NodAccent") : Color(.secondarySystemBackground)
                    )
                )
                .contentTransition(.symbolEffect(.replace.downUp))
                .symbolEffect(
                    .pulse,
                    options: .repeat(2),
                    isActive: !hasTappedMic && !isRecording
                )
        }
        .animation(.easeInOut(duration: 0.15), value: isRecording)
        .accessibilityLabel(isRecording ? "Stop dictation" : "Start dictation")
        .accessibilityHint(isRecording
            ? "Inserts the transcript into the message field"
            : "Records what you say and transcribes it")
    }

    /// Siri-style edge glow that traces the phone's outer rectangle
    /// when dictation is active. Single stroked rounded-rectangle
    /// with a blurred NodAccent outline. No rotation, no
    /// repeatForever — just an opacity fade driven by `isRecording`
    /// via the parent's `.animation` modifier. Safe by construction.
    private var recordingEdgeGlow: some View {
        RoundedRectangle(cornerRadius: 58, style: .continuous)
            .inset(by: -4)
            .stroke(Color("NodAccent"), lineWidth: 16)
            .blur(radius: 14)
    }

    /// Handles transcript delivery. When the recognizer commits, we
    /// pick up `lastFinalText`, append it to the input field, and
    /// focus the text field so the user can edit or send. Empty
    /// commit silently dismisses. Fallback on .idle covers the case
    /// where SwiftUI coalesced .committed→.idle into a single
    /// delivery.
    private func handleDictationStateChange(
        from oldValue: DictationRecognizer.State,
        to newValue: DictationRecognizer.State
    ) {
        // `.committed` is the only reliable delivery signal. The old
        // `.idle`/`.unavailable` fallback (which read lastFinalText)
        // was dangerous — it could re-insert the previous session's
        // transcript if the new start() failed before committing.
        // The recognizer now clears lastFinalText at start(), and
        // SpeechAnalyzer's stream-based results reliably hit
        // `.committed` before transitioning to `.idle`.
        if case .committed = newValue {
            deliverTranscript(dictationRecognizer.lastFinalText)
        }
    }

    private func deliverTranscript(_ finalText: String) {
        let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Append to existing text, trim-aware so whitespace-only
        // drafts don't leave leading spaces before the transcript.
        let existing = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        inputText = existing.isEmpty ? trimmed : existing + " " + trimmed
        committedAt = Date()
        // Deliberately do NOT raise the keyboard here. The voice
        // experience is spoken, not typed — popping the keyboard right
        // after commit yanks the user out of the voice flow and into
        // typing mode. The send button sits in the input row and is
        // tappable regardless of focus, so they can ship the message
        // without touching the keyboard. If they want to edit, they
        // tap the field themselves.
    }

    /// Tap dispatch for the two-state send/stop button.
    private func handleSendButtonTap(role: SendButtonRole) {
        switch role {
        case .stop:
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            inferenceTask?.cancel()
        case .send:
            sendMessage()
        }
    }

    private func isSendButtonDisabled(for role: SendButtonRole) -> Bool {
        switch role {
        case .stop: return inferenceTask == nil
        case .send: return !sendEnabled
        }
    }

    /// Fill color for the send/stop button. NodAccent when ready to
    /// send; neutral gray when streaming (stop); dim tertiary when
    /// genuinely disabled (empty input pre-hydrate).
    private func sendButtonFill(for role: SendButtonRole) -> Color {
        switch role {
        case .stop:
            return Color(.secondarySystemBackground)
        case .send:
            return sendEnabled ? Color("NodAccent") : Color(.tertiarySystemFill)
        }
    }

    private func sendButtonIconColor(for role: SendButtonRole) -> Color {
        switch role {
        case .stop:
            // Black on the gray stop circle for high contrast in both
            // light and dark modes. `.primary` would invert with theme
            // and lose contrast against the neutral gray fill.
            return .primary
        case .send:
            return sendEnabled ? .black : .secondary
        }
    }

    private var sendEnabled: Bool {
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard !isInferring else { return false }
        // Gate on store hydration. Pre-hydrate, `store.messages` is
        // empty because the SQLite fetch is still in flight from
        // `.task`. Sending in that window would seed the AFM session
        // with empty history (since `buildInferenceInputs` reads
        // `store.messages`) and misfeed the model. Hydrate completes
        // in 50-300 ms during the splash, so users typically never
        // see a disabled send. The edge case is covered defensively.
        guard store.isHydrated else { return false }
        // Was `if case .ready = engineHolder.mlxEngineLoadState`, which is
        // backed by the fine-grained 5 Hz download observer. Reading that
        // here would cause ChatView's body to re-evaluate on every progress
        // tick. The coarse `isModelReady` @Published flips only on actual
        // ready/not-ready transitions, so reading it is nearly free.
        return engineHolder.isModelReady
    }

    // MARK: - Entity disambiguation banner
    //
    // Shown when entity extraction produced a name that fuzzy-matches an
    // existing entity — the model thinks it might be the same thing but
    // isn't sure. Rather than guessing and polluting memory with a wrong
    // merge, we ask the user.
    //
    // Copy: plain and direct. Same tone as Nod's other UI — not a modal
    // dialog, just a quiet question between messages.
    @ViewBuilder
    private func disambiguationBanner(for pending: PendingDisambiguation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Is this the same as someone you mentioned before?")
                .font(.subheadline.weight(.medium))

            VStack(alignment: .leading, spacing: 4) {
                Text("New: \(pending.candidate.canonicalName)" +
                     (pending.candidate.role.flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Known: \(pending.existing.canonicalName)" +
                     (pending.existing.role.flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    entityStore.resolve(pending, as: .same)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Text("Same person")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color("NodAccent"))
                        .foregroundStyle(.black)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    entityStore.resolve(pending, as: .new)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Text("New")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color(.tertiarySystemFill))
                        .foregroundStyle(.primary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Fallback banner
    //
    // Shown when LaunchCrashBreaker flipped the engine to Apple
    // Intelligence. Dismissable — the user sees it once per fallback
    // event, never on a clean launch. Tone: explain what happened,
    // reassure it's reversible, point them at the menu.
    private var fallbackBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(crashBreaker.bannerText)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                crashBreaker.dismissBanner()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // The readiness-bar UI lives in the `MLXReadinessBar` struct at the
    // bottom of this file. It observes `engineHolder.downloadObserver`
    // directly (not `engineHolder`), so only that subview re-renders on
    // progress ticks. ChatView stays at rest during a download.

    /// Display name of the currently-active MLX engine, or an empty
    /// string when we're on AFM. Used throughout the readiness-card
    /// copy so "Downloading Qwen 3 Instruct 2507…" / "Loading Gemma 4
    /// E2B Text into memory…" show the right model.
    private var activeModelDisplayName: String {
        engineHolder.preference.mlxSpec?.displayName ?? ""
    }

    /// Total bytes for the active model's manifest. Zero if AFM.
    private var activeModelTotalBytes: Int64 {
        engineHolder.preference.mlxSpec?.totalBytes ?? 0
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard sendEnabled else { return }
        inputText = ""
        store.append(Message(role: .user, text: text))
        triggerNod()
        respond(to: text)
    }

    private func triggerNod() {
        nodTrigger &+= 1
        // Light tap on send. The user initiated this; keep the feedback
        // quiet and confirmatory rather than demanding attention.
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func respond(to text: String) {
        guard let engine = engineHolder.engine else {
            // Build bug: a prompt file isn't being copied into the bundle.
            // Developer-facing message — should never reach a real user.
            store.append(Message(role: .assistant, text: "Build error: prompts/ not found in app bundle. Check Xcode → Build Phases → Copy Bundle Resources."))
            return
        }
        isInferring = true
        pendingSnapshot = ""
        // Insert an empty assistant message. Filtered out of context we
        // build for the model; filled with the reply as tokens stream in.
        // Capture the ID so the cancel / completion paths can target it
        // by identity rather than position (robust to interleaved rows).
        let placeholder = Message(role: .assistant, text: "")
        let placeholderID = placeholder.id
        store.append(placeholder)

        // Split inputs: systemBlock (personalization + summary + entity
        // context for entities this message references) goes into the
        // engine's system message. `history` is the un-summarized recent
        // turns — the engine passes these as real chat turns so the
        // model's multi-turn attention actually engages.
        let inputs = store.buildInferenceInputs(currentUserMessage: text)

        // Token budget sized to this user's response-style preference.
        let options = GenerationOptions.forResponseStyle(
            PersonalizationStore.shared.current.responseStyle
        )

        // Reset the idle-unload timer. While the user is actively chatting
        // we hold the weights; the timer only fires after 10 quiet
        // minutes (or a background transition).
        engineHolder.noteActivity()

        // 30 Hz flush tick. Runs on the main actor concurrently with the
        // stream consumer. On each tick, if pendingSnapshot has content
        // and differs from the bubble's current text, push it into the
        // store in-memory (no WAL write per tick). The final commit
        // (which DOES enqueue a WAL write) happens once on stream
        // completion.
        flushTask?.cancel()
        flushTask = Task { @MainActor in
            var lastFlushed = ""
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 33_000_000) // ~30 Hz
                if !pendingSnapshot.isEmpty && pendingSnapshot != lastFlushed {
                    store.updateLastAssistantMessageInMemory(with: pendingSnapshot)
                    lastFlushed = pendingSnapshot
                }
            }
        }

        // The streaming task. Holds the handle so the stop button can
        // cancel it. Cancellation cascades: Task.cancel → stream
        // continuation torn down → onTermination → producer task
        // cancelled → GPU stops generating.
        inferenceTask = Task { @MainActor in
            var wasError = false
            var errorReply: String = ""
            var lastSnapshot = ""
            do {
                for try await snapshot in engine.streamResponse(
                    to: text,
                    context: inputs.systemBlock,
                    history: inputs.history,
                    options: options
                ) {
                    try Task.checkCancellation()
                    lastSnapshot = snapshot
                    pendingSnapshot = snapshot
                }
            } catch is CancellationError {
                // User tapped stop. Tear down the flush tick so the
                // final-commit path below runs before the stream is
                // reopened by a new send.
                flushTask?.cancel()
                flushTask = nil
                if lastSnapshot.isEmpty {
                    // No tokens landed — remove the empty placeholder
                    // entirely rather than leave an orphan bubble.
                    store.removeLastAssistantMessage()
                } else {
                    // Persist the partial reply + mark cancelled so the
                    // "stopped" tag renders now AND after relaunch.
                    store.replaceLastAssistantMessage(with: lastSnapshot)
                    store.markAssistantCancelled(id: placeholderID)
                }
                isInferring = false
                inferenceTask = nil
                pendingSnapshot = ""
                return
            } catch InferenceError.modelNotReady {
                errorReply = Self.modelNotReadyMessage()
                wasError = true
            } catch InferenceError.guardrailViolation {
                errorReply = "I'd rather not respond to that."
                wasError = true
            } catch {
                errorReply = "Something went wrong. Try again."
                wasError = true
            }

            // Normal completion or error path. Stop the flush tick
            // FIRST so there's no race between "flush tick is writing
            // pendingSnapshot" and "commit path writes final text".
            flushTask?.cancel()
            flushTask = nil

            let finalText: String
            if wasError {
                finalText = errorReply
            } else if lastSnapshot.isEmpty {
                // Guard against empty replies (e.g. Qwen burns its
                // tokens inside a <think> block). Without this the
                // placeholder stays empty and typing-dots show
                // indefinitely with no way to recover.
                finalText = "Something went wrong. Try again."
                wasError = true
            } else {
                finalText = lastSnapshot
            }

            // Commit the final text (single WAL write per reply).
            store.replaceLastAssistantMessage(with: finalText)
            isInferring = false
            inferenceTask = nil
            pendingSnapshot = ""

            // Haptic on arrival. Soft tap for a real reply; warning
            // pattern for an error so the user feels the difference
            // without reading.
            if wasError {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            } else {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            }
        }
    }

    /// Build the user-facing "model not ready" message, branching on the
    /// current engine preference + AFM-specific availability reason.
    private static func modelNotReadyMessage() -> String {
        switch EnginePreferenceStore.current {
        case .apple:
            switch DeviceCapability.afmStatus {
            case .notSupported:
                return "Your iPhone doesn't support Apple Intelligence. Tap the menu to pick an on-device model instead."
            case .disabledInSettings:
                return "Apple Intelligence is turned off. Flip it on in Settings → Apple Intelligence, or switch to an on-device model from the menu."
            case .available:
                return "Apple Intelligence is warming up. Try sending again in a moment."
            }
        case .qwen3, .qwen35, .gemma4:
            return "\(EnginePreferenceStore.current.displayName) isn't ready yet. The model still needs to finish downloading."
        }
    }

    /// Gate for regenerate UI on a given assistant message. Current rule:
    /// only the most-recent assistant reply can be regenerated AND we
    /// must have a preceding user message to re-send. Error bubbles AND
    /// cancelled replies both qualify (retry-after-error + retry-after-
    /// stop are the canonical uses). Matches the plan's visibility rule.
    private func canRegenerate(_ msg: Message) -> Bool {
        guard msg.role == .assistant else { return false }
        guard store.messages.last?.id == msg.id else { return false }
        // There must be at least one prior user message we can re-send.
        return store.messages.reversed().contains(where: { $0.role == .user })
    }

    /// Regenerate the last assistant reply. Delete-after-success
    /// sequencing: the OLD reply stays visible while the new one
    /// streams. On first token of the new reply, the old one is
    /// removed. On error before first token, the old one stays intact
    /// and the error bubble slots in after it — user never loses
    /// context.
    private func regenerate() {
        guard !isInferring else { return }
        guard let last = store.messages.last, last.role == .assistant else { return }
        let oldAssistantID = last.id

        // Find the most recent user message via backward search.
        // `messages[count-2]` would be fragile if summary/placeholder
        // rows ever get interleaved (Codex NEW-6 from plan-eng-review).
        guard let lastUserText = store.messages.reversed().first(where: { $0.role == .user })?.text else {
            return
        }

        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        // Pre-regenerate cleanup: schedule the old reply for deletion
        // AFTER the new reply lands a token. Implement via a one-shot
        // observer on the store — when the NEW placeholder (appended
        // by respond()) gets its first non-empty snapshot, remove the
        // old one.
        //
        // Simpler: delete the old ID right before we append the new
        // placeholder IF we can guarantee the new stream will start.
        // That fails the delete-after-success contract on immediate
        // error. So we use a Task observer:
        Task { @MainActor in
            // Wait for the new placeholder to appear AND gain content,
            // OR for the inferenceTask to finish (error path).
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000) // 20 Hz poll
                // Error path: respond() finished without the new reply
                // landing any content. Leave the OLD reply in place.
                // `respond()` has already appended an error bubble at
                // the end of `messages`.
                if inferenceTask == nil {
                    // If the stream produced no text (empty snapshot)
                    // OR we hit an error, don't delete the old reply.
                    // User can still see the previous content.
                    return
                }
                // Happy path: the NEW placeholder is the last message
                // and has gained text. Delete the old one and exit.
                if let newLast = store.messages.last,
                   newLast.id != oldAssistantID,
                   !newLast.text.isEmpty {
                    store.removeAssistantMessage(id: oldAssistantID)
                    return
                }
            }
        }

        respond(to: lastUserText)
    }

    // MARK: - Message spacing

    /// Top padding between message bubbles. Tight for same-sender follow-ups
    /// so a block of thought reads as one block; wider when the speaker
    /// changes so the exchange has visible rhythm. Nod-blink rows get a
    /// bit more breathing room because the eyes are visually heavy.
    ///
    /// Breakpoint-aware: if the previous row is a breakpoint (date separator
    /// or time gap), the breakpoint itself provides the vertical space —
    /// no top padding on the message that follows it.
    private static func topPadding(for msg: Message, prevRow: ChatRow?) -> CGFloat {
        switch prevRow {
        case .none:                             return 0
        case .breakpoint:                       return 0
        case .message(let prev):
            if msg.role == .nod || prev.role == .nod { return 16 }
            return msg.role == prev.role ? 4 : 14
        }
    }

    // MARK: - Chat row composition

    /// One renderable item in the message list — either a message bubble
    /// or a visual breakpoint (date separator / time gap). Breakpoints
    /// are derived from adjacent messages' `createdAt`, not persisted.
    enum ChatRow: Identifiable {
        /// Visual separator. `isDate` distinguishes a day-level label
        /// ("Today", "Yesterday", "Mon Mar 15") from a time-only label
        /// inserted on same-day gaps ("2:30 PM"). The id is derived
        /// deterministically from the message that follows it, so
        /// SwiftUI can diff stably across re-renders.
        case breakpoint(id: String, label: String, isDate: Bool)
        case message(Message)

        var id: String {
            switch self {
            case .breakpoint(let id, _, _): return id
            case .message(let m):           return m.id.uuidString
            }
        }
    }

    /// Walk the messages and emit a row sequence with date separators
    /// and time gaps interleaved. Rules:
    ///   - First message in history → preceded by a date separator.
    ///   - Calendar-day change → date separator.
    ///   - Same-day gap over 10 minutes → time-only separator.
    ///   - Otherwise → no separator.
    ///
    /// The 10-minute threshold matches iMessage's default (it uses
    /// somewhere around 7-15 minutes depending on context). Short
    /// enough to mark genuine pauses, long enough to avoid cluttering
    /// a normal back-and-forth with timestamps every turn.
    static func chatRows(from messages: [Message]) -> [ChatRow] {
        guard !messages.isEmpty else { return [] }
        var rows: [ChatRow] = []
        let calendar = Calendar.current
        let gapThreshold: TimeInterval = 10 * 60

        for (i, msg) in messages.enumerated() {
            if i == 0 {
                rows.append(.breakpoint(
                    id: "break-before-\(msg.id.uuidString)",
                    label: dayLabel(for: msg.createdAt),
                    isDate: true
                ))
            } else {
                let prev = messages[i - 1]
                if !calendar.isDate(prev.createdAt, inSameDayAs: msg.createdAt) {
                    rows.append(.breakpoint(
                        id: "break-before-\(msg.id.uuidString)",
                        label: dayLabel(for: msg.createdAt),
                        isDate: true
                    ))
                } else if msg.createdAt.timeIntervalSince(prev.createdAt) > gapThreshold {
                    rows.append(.breakpoint(
                        id: "break-before-\(msg.id.uuidString)",
                        label: timeLabel(for: msg.createdAt),
                        isDate: false
                    ))
                }
            }
            rows.append(.message(msg))
        }
        return rows
    }

    /// "Today" / "Yesterday" / "Monday" (this week) / "Mar 15" (same
    /// year) / "Mar 15, 2025" (older). iMessage-style.
    private static func dayLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date)     { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }

        // "This week" window: last 6 days → just the weekday name.
        let daysAgo = calendar.dateComponents([.day], from: date, to: Date()).day ?? 0
        let formatter = DateFormatter()
        formatter.locale = .current
        if daysAgo < 7 {
            formatter.dateFormat = "EEEE"       // "Monday"
            return formatter.string(from: date)
        }

        let sameYear = calendar.component(.year, from: date)
            == calendar.component(.year, from: Date())
        formatter.dateFormat = sameYear ? "MMM d" : "MMM d, yyyy"
        return formatter.string(from: date)
    }

    /// Locale-aware time-only label ("2:30 PM" or "14:30" depending on
    /// user's settings).
    private static func timeLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}

// MARK: - BreakpointView

/// Centered separator shown between messages when the day changes or
/// after a long same-day gap. Caption typography, secondary foreground,
/// modest vertical padding — a gentle interruption of the bubble flow,
/// not a section heading.
private struct BreakpointView: View {
    let label: String
    let isDate: Bool

    var body: some View {
        Text(label)
            .font(isDate ? .caption.weight(.semibold) : .caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, isDate ? 16 : 12)
            .padding(.bottom, isDate ? 8 : 4)
            .accessibilityLabel(isDate ? "Date: \(label)" : "Time: \(label)")
    }
}

// MARK: - MessageBubble

struct MessageBubble: View {
    let message: Message
    /// True when this bubble is the last message in the conversation AND
    /// it's an assistant reply. Gates the inline retry button and the
    /// "Regenerate" context menu entry. Defaults false so older call
    /// sites compile unchanged.
    var isLast: Bool = false
    /// Called when the user taps Regenerate (inline button or context
    /// menu). Nil means the parent isn't participating — UI affordances
    /// that depend on it stay hidden. Provided only for the last
    /// assistant bubble.
    var onRegenerate: (() -> Void)? = nil

    @State private var nodTriggerForThisBubble: Int = 0

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 40)
                bubble(color: Color(.tertiarySystemFill))
            } else if message.role == .assistant {
                // Bubble goes directly into the HStack — NOT wrapped in
                // a VStack. An earlier version wrapped it in a
                // `VStack(alignment: .leading)` to host the "stopped"
                // tag underneath, but SwiftUI's layout algorithm gives
                // a VStack-in-HStack a different width-request profile
                // than a raw Text-in-HStack, and on longer replies the
                // bubble could bleed past the leading padding of the
                // LazyVStack (flush with the screen edge, left rounded
                // corner cut off). The "stopped" tag instead renders as
                // an overlay below the bubble — same visual, zero
                // layout surprise.
                //
                // `.padding(.bottom, 20)` reserves vertical space under
                // the bubble when cancelled, so the overlay fits
                // without overlapping the next row.
                bubble(color: Color(.secondarySystemBackground))
                    .padding(.bottom, message.wasCancelled && !message.text.isEmpty ? 20 : 0)
                    .overlay(alignment: .bottomLeading) {
                        if message.wasCancelled && !message.text.isEmpty {
                            Text("stopped")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 6)
                                .accessibilityLabel("Reply was stopped")
                        }
                    }
                Spacer(minLength: 40)
            } else {
                // .nod — a centered inline blink. Fires once on appear so
                // scrolling back through history sees the bubble as a static
                // pair of eyes (correct — it's already happened), but the
                // fresh arrival animates.
                Spacer()
                NodAnimation(trigger: nodTriggerForThisBubble)
                    .accessibilityLabel("Nod acknowledged")
                    .onAppear {
                        nodTriggerForThisBubble += 1
                    }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func bubble(color: Color) -> some View {
        if message.text.isEmpty && message.role == .assistant {
            // In-progress: typing-dots placeholder instead of empty bubble.
            HStack(spacing: 4) {
                ForEach(0..<3) { _ in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityLabel("Nod is thinking")
        } else {
            Text(message.text)
                .font(.body)
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(color)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityLabel(message.role == .user ? "You said: \(message.text)" : "Nod said: \(message.text)")
                // Long-press to copy or share. iOS renders this as a
                // standard context-menu preview with the bubble lifted —
                // the same affordance Messages uses. Only on text bubbles;
                // the typing-dots placeholder has nothing to share, and
                // .nod has no text.
                //
                // ShareLink is the iOS 16+ native share affordance — it
                // handles the iPad popover anchor itself, avoiding the
                // UIActivityViewController-inside-a-sheet crash pattern.
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = message.text
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    ShareLink(item: message.text) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    // Regenerate — visible only on the LAST assistant
                    // reply (which includes cancelled and error bubbles;
                    // retry-after-error is the canonical use case).
                    if isLast, message.role == .assistant, let onRegenerate {
                        Button {
                            onRegenerate()
                        } label: {
                            Label("Regenerate", systemImage: "arrow.clockwise")
                        }
                    }
                }
        }
    }
}

// A ButtonStyle that renders its label unchanged on every state — no
// opacity dim, no scale, no tint shift when pressed. Used for the toolbar
// mascot so that tapping it doesn't flash the orange NodAccent toward
// yellow. Intentionally ignores `configuration.isPressed`.
private struct MascotButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

// MARK: - MLXReadinessBar (isolated subview)
//
// The download/load readiness card. Lives as a standalone view so it can
// observe the fine-grained `DownloadStateObserver` in isolation. During
// an active download, `observer.state` changes ~5 times per second, which
// invalidates this subview 5 Hz. ChatView — which observes `engineHolder`
// (coarse) but NOT `observer` (fine) — is unaffected and stays at 120 fps.
//
// State taxonomy:
//   .downloading(m)         → animated bar, live bytes/speed/ETA, Cancel
//   .waitingForNetwork(m)   → frozen bar, "we'll pick up when you're online", Cancel
//   .waitingForWifi(m)      → frozen bar, "Use cellular this time" + Cancel
//   .paused(m)              → frozen bar, centered [Resume download] button
//   .loading                → spinner + "Loading <model> into memory…"
//   .failed(msg)            → typed error title + body + Try again
//   .notLoaded / .ready     → card hidden
//
// Variant B layout: stacked hierarchy. Bytes get their own line (the
// primary "how far along am I" signal). Speed + ETA share the second
// metadata line in secondary. Cancel is bottom-right, plain text.
//
// Action handlers are passed in as closures rather than handing over the
// full `EngineHolder` reference — that way, this view has no
// @ObservedObject dependency on EngineHolder and its own body
// invalidations don't escape upward.
private struct MLXReadinessBar: View {
    @ObservedObject var observer: DownloadStateObserver
    let modelDisplayName: String
    let totalBytes: Int64
    let onRetry: () -> Void
    let onResume: () -> Void
    let onUseCellular: () -> Void
    let onRequestCancel: () -> Void

    var body: some View {
        content
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            // State-transition animation is scoped to this subview — so it
            // doesn't trip invalidation of ChatView. Keyed on the coarse
            // case identity, not the associated metrics, so live progress
            // updates within .downloading don't cause the whole card to
            // cross-fade every tick.
            .animation(.easeInOut(duration: 0.25), value: stateCaseKey)
    }

    @ViewBuilder
    private var content: some View {
        switch observer.state {
        case .notLoaded, .ready:
            EmptyView()

        case .downloading(let metrics):
            card {
                downloadingCard(metrics: metrics)
            }

        case .waitingForNetwork(let metrics):
            card {
                waitingCard(
                    metrics: metrics,
                    header: "Waiting for the network…",
                    body: "We'll pick up when you're back online.",
                    showCellularLink: false
                )
            }

        case .waitingForWifi(let metrics):
            card {
                waitingCard(
                    metrics: metrics,
                    header: "Waiting for Wi-Fi…",
                    body: "Nod will continue when you're back on Wi-Fi.",
                    showCellularLink: true
                )
            }

        case .paused(let metrics):
            card {
                pausedCard(metrics: metrics)
            }

        case .loading:
            card {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading \(modelDisplayName) into memory…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

        case .failed(let msg):
            card {
                VStack(alignment: .leading, spacing: 6) {
                    Text(failureTitle(msg: msg))
                        .font(.subheadline.weight(.medium))
                    Text(failureBody(msg: msg))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Try again", action: onRetry)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color("NodAccent"))
                        .padding(.top, 2)
                }
            }
        }
    }

    // MARK: - Card chrome

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder _ inner: () -> Content) -> some View {
        inner()
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - State variants

    @ViewBuilder
    private func downloadingCard(metrics: DownloadMetrics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Downloading \(modelDisplayName)…")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Int(metrics.fraction * 100))%")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            // `.animation(nil, value: metrics.fraction)` kills the
            // default implicit tween on ProgressView value changes. At
            // 5 Hz emissions, each implicit tween overlaps the next and
            // produces visible juddering on the bar itself — counter-
            // intuitively, disabling the animation makes the bar LOOK
            // smoother because each step renders crisply.
            ProgressView(value: metrics.fraction)
                .tint(Color("NodAccent"))
                .animation(nil, value: metrics.fraction)

            // Line 1: byte count — the primary "how far along" signal.
            Text(formatByteProgress(written: metrics.bytesWritten, total: metrics.totalBytes))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.primary)

            // Line 2: speed · ETA (caption secondary). Hidden until we
            // have a stable rate reading; otherwise we'd show "0 MB/s"
            // for the first second which looks like something's wrong.
            if let subtitle = formatSpeedAndETA(metrics: metrics) {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack {
                Spacer()
                Button("Cancel", action: onRequestCancel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func waitingCard(
        metrics: DownloadMetrics,
        header: String,
        body: String,
        showCellularLink: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(header)
                    .font(.subheadline.weight(.medium))
                Spacer()
            }

            ProgressView(value: metrics.fraction)
                .tint(Color("NodAccent"))
                .animation(nil, value: metrics.fraction)

            Text(formatByteProgress(written: metrics.bytesWritten, total: metrics.totalBytes))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.primary)

            Text(body)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                if showCellularLink {
                    Button("Use cellular this time", action: onUseCellular)
                        .font(.subheadline)
                        .foregroundStyle(Color("NodAccent"))
                        .buttonStyle(.plain)
                }
                Spacer()
                Button("Cancel", action: onRequestCancel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func pausedCard(metrics: DownloadMetrics) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(modelDisplayName) download paused")
                .font(.subheadline.weight(.medium))

            ProgressView(value: metrics.fraction)
                .tint(Color("NodAccent"))
                .animation(nil, value: metrics.fraction)

            Text("\(formatByteProgress(written: metrics.bytesWritten, total: metrics.totalBytes)) downloaded")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(action: onResume) {
                    Text("Resume download")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Color("NodAccent"))
                        .foregroundStyle(.black)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.top, 2)
        }
    }

    // MARK: - Animation key
    //
    // For state-case transitions (downloading → paused, waiting → ready)
    // we want a fade. For progress ticks WITHIN .downloading we do NOT
    // want a fade on the whole card. This computed property maps each
    // state to a stable integer that changes only on case identity, not
    // on the associated DownloadMetrics. Keyed `.animation(value:)` on
    // this instead of `observer.state` gives us the right granularity.
    private var stateCaseKey: Int {
        switch observer.state {
        case .notLoaded:         return 0
        case .downloading:       return 1
        case .waitingForNetwork: return 2
        case .waitingForWifi:    return 3
        case .paused:            return 4
        case .loading:           return 5
        case .ready:             return 6
        case .failed:            return 7
        }
    }

    // MARK: - Failure copy

    private func failureTitle(msg: String) -> String {
        if msg.contains("downloadFailedNoNetwork") {
            return "Can't reach the download server"
        }
        if msg.contains("downloadFailedDiskFull") {
            return "Not enough space for \(modelDisplayName)"
        }
        return "\(modelDisplayName) failed to load"
    }

    private func failureBody(msg: String) -> String {
        let sizeGB = String(format: "%.1f", Double(totalBytes) / 1_000_000_000)
        if msg.contains("downloadFailedNoNetwork") {
            return "Connect to Wi-Fi and try again. The download is ~\(sizeGB) GB."
        }
        if msg.contains("downloadFailedDiskFull") {
            return "Free up ~\(sizeGB) GB on your device, then try again."
        }
        return "Something went wrong. Try again, or switch back to Apple Intelligence in the menu."
    }

    // MARK: - Formatters
    //
    // Speed + byte numbers round to coarse increments deliberately. At
    // 3 MB/s and 5 Hz emits, showing "721 MB, 722 MB, 725 MB" every
    // fraction of a second reads as twitchy. Rounding to nearest 10 MB
    // gives one visible tick every ~3 s — the right rhythm for a long
    // transfer. Underlying metrics still arrive at full precision; only
    // the display is coarsened.

    private func formatByteProgress(written: Int64, total: Int64) -> String {
        "\(formatCoarseBytes(written)) of \(formatCoarseBytes(total))"
    }

    private func formatCoarseBytes(_ bytes: Int64) -> String {
        let oneGB: Int64 = 1_000_000_000
        if bytes >= oneGB {
            let gb = (Double(bytes) / Double(oneGB))
            return String(format: "%.1f GB", gb)
        } else {
            let mb = Int((Double(bytes) / 1_000_000 / 10).rounded()) * 10
            return "\(mb) MB"
        }
    }

    private func formatSpeedAndETA(metrics: DownloadMetrics) -> String? {
        let rate = metrics.bytesPerSecond
        guard rate > 0 else { return nil }

        let rateString = formatCoarseSpeed(rate)

        guard let seconds = metrics.secondsRemaining, seconds.isFinite, seconds > 0 else {
            return rateString
        }

        let etaString: String
        if seconds < 60 {
            etaString = "less than a minute remaining"
        } else if seconds < 3600 {
            let minutes = Int((seconds / 60).rounded())
            etaString = "about \(minutes) min remaining"
        } else {
            let hours = Int((seconds / 3600).rounded())
            etaString = "about \(hours) hr remaining"
        }
        return "\(rateString)  ·  \(etaString)"
    }

    private func formatCoarseSpeed(_ bytesPerSec: Double) -> String {
        let mbPerSec = bytesPerSec / 1_000_000
        if mbPerSec >= 1.0 {
            return "\(Int(mbPerSec.rounded())) MB/s"
        }
        let kbPerSec = bytesPerSec / 1000
        let rounded = Int((kbPerSec / 50).rounded()) * 50
        return "\(max(50, rounded)) KB/s"
    }
}

// MARK: - AFMUnavailableOnboarding
//
// First-run empty state shown when the user's active preference is
// Apple Intelligence but AFM isn't available on this device. Three
// branches, keyed on `DeviceCapability.afmStatus` + `canRunMLX4BClass`:
//
//   1. disabledInSettings: AFM-capable hardware, user disabled it. Copy
//      mentions the Settings path; Qwen 3 is the recommended download.
//   2. notSupported + canRunMLX: hardware can't run AFM (iPhone 15 base
//      et al). Same layout, different body copy — no Settings path.
//   3. notSupported + !canRunMLX: dead-end. Honest "needs newer iPhone"
//      with no CTAs. No model downloads would fit either.
//
// Layout: 88pt mascot centered, welcome headline, body copy, primary
// CTA (NodAccent-filled card = recommended model, Qwen 3 Instruct 2507
// because proven > newest for a first-time user committing to a 5-min
// download), OR divider, two secondary cards (Gemma 4, Qwen 3.5 in
// newest-first order), footer.
//
// Tap on any model → `onPickModel(pref)` → ChatView calls
// `engineHolder.setPreference(...)` which kicks off the download.
// MLXReadinessBar takes over rendering as soon as state transitions
// out of .notLoaded.
private struct AFMUnavailableOnboarding: View {
    let afmStatus: DeviceCapability.AFMStatus
    let canRunMLX: Bool
    let onPickModel: (EnginePreference) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                heroMascot
                content
                Spacer(minLength: 40)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
        .accessibilityLabel(accessibilityIntro)
    }

    // MARK: Hero

    /// 88pt mascot — the hero size. Larger than the 32pt nav-bar
    /// mascot; codified as the "hero moment" token. Uses the canonical
    /// NodMascot so the onboarding first-impression matches the app
    /// icon users just tapped.
    private var heroMascot: some View {
        NodMascot(size: 88)
            .padding(.top, 64)
            .padding(.bottom, 28)
            .opacity(afmStatus == .notSupported && !canRunMLX ? 0.85 : 1.0)
    }

    // MARK: Branch router

    @ViewBuilder
    private var content: some View {
        switch afmStatus {
        case .available:
            // Shouldn't reach this view when AFM is available, but be
            // defensive: show the MLX-only copy as a safe fallback.
            mlxOnlyBranch
        case .disabledInSettings:
            afmDisabledBranch
        case .notSupported:
            if canRunMLX {
                mlxOnlyBranch
            } else {
                neitherBranch
            }
        }
    }

    // MARK: Branch: AFM off in Settings

    @ViewBuilder
    private var afmDisabledBranch: some View {
        welcomeHeadline("Let's get you set up.")
        bodyCopy("Apple Intelligence is off on this iPhone. You can turn it on in Settings → Apple Intelligence & Siri, or pick an on-device model below.")
        modelPickerStack
        onDeviceFooter
    }

    // MARK: Branch: MLX-only (AFM hardware-unsupported + MLX available)

    @ViewBuilder
    private var mlxOnlyBranch: some View {
        welcomeHeadline("Let's get you set up.")
        bodyCopy("Nod runs the AI on your device. Your iPhone can't use Apple's built-in one, so pick one of these instead.")
        modelPickerStack
        onDeviceFooter
    }

    // MARK: Branch: Neither (no AFM, no MLX) — dead end

    @ViewBuilder
    private var neitherBranch: some View {
        welcomeHeadline("Nod needs a newer iPhone.")
        bodyCopy("Nod runs the AI on your device, and the models won't fit in this iPhone's memory.")
        requirementsCard
        Text("We'd rather be honest than give you a bad experience. The whole point is that your conversations stay on your device.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.top, 18)
            .padding(.horizontal, 8)
    }

    // MARK: Shared pieces

    private func welcomeHeadline(_ text: String) -> some View {
        Text(text)
            .font(.title3.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.bottom, 14)
    }

    private func bodyCopy(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.bottom, 28)
            .padding(.horizontal, 4)
    }

    /// Primary + OR + two secondary. Recommended = Qwen 3 (proven),
    /// alternates newest-first (Gemma 4, Qwen 3.5).
    @ViewBuilder
    private var modelPickerStack: some View {
        modelCard(pref: .qwen3, style: .primary, roleOverride: "Recommended")
        orDivider
        modelCard(pref: .gemma4, style: .secondary, roleOverride: nil)
            .padding(.top, 8)
        modelCard(pref: .qwen35, style: .secondary, roleOverride: nil)
            .padding(.top, 8)
    }

    private var orDivider: some View {
        Text("OR")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.6)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
    }

    private enum ModelCardStyle { case primary, secondary }

    /// One tappable model option. Primary = NodAccent-filled (the
    /// recommended path); secondary = secondarySystemBackground fill.
    /// Whole card is the tap target. No chevron button — arrow is a
    /// visual hint, not a separate interactive element.
    @ViewBuilder
    private func modelCard(pref: EnginePreference, style: ModelCardStyle, roleOverride: String?) -> some View {
        let spec = pref.mlxSpec
        let role = roleOverride ?? (spec?.roleLabel ?? "")
        let sizeLabel = spec.map { Self.formatSize($0.totalBytes) } ?? ""
        let meta = role.isEmpty ? sizeLabel : "\(role) · \(sizeLabel)"
        let title = pref.displayName

        Button {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            onPickModel(pref)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(style == .primary ? .semibold : .medium))
                        .foregroundStyle(style == .primary ? .black : .primary)
                    Text(meta)
                        .font(.caption)
                        .foregroundStyle(style == .primary
                            ? Color.black.opacity(0.65)
                            : Color.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(style == .primary
                        ? Color.black
                        : Color.secondary.opacity(0.7))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, style == .primary ? 15 : 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(style == .primary
                ? Color("NodAccent")
                : Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(meta), double-tap to download")
    }

    private var requirementsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("WHAT YOU'LL NEED")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            Text("iPhone 15 Pro or newer, or any iPhone with at least 6 GB of memory.")
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.top, 4)
    }

    /// Footer shown on both MLX-capable branches (MLX-only and AFM-off).
    /// Not on "neither" — that branch has its own reassurance copy.
    private var onDeviceFooter: some View {
        Text("All on-device. Nothing sent to a server. Wi-Fi recommended for the download.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.top, 18)
            .padding(.horizontal, 8)
    }

    // MARK: Helpers

    /// Format bytes as a coarse size string. Mirrors the logic in
    /// SidebarView.formatCoarseSize so the two surfaces show identical
    /// numbers for the same model. If the rounding logic ever diverges,
    /// unify on a shared helper (noted for DESIGN.md follow-up).
    private static func formatSize(_ bytes: Int64) -> String {
        let oneGB: Int64 = 1_000_000_000
        if bytes >= oneGB {
            return String(format: "%.1f GB", Double(bytes) / Double(oneGB))
        }
        let mb = Int((Double(bytes) / 1_000_000 / 10).rounded()) * 10
        return "\(mb) MB"
    }

    /// VoiceOver intro for the whole onboarding screen. Individual
    /// cards have their own labels; this one provides orientation.
    private var accessibilityIntro: String {
        switch afmStatus {
        case .available:
            return "Pick a model to start Nod."
        case .disabledInSettings:
            return "Apple Intelligence is off. Turn it on in Settings, or pick an on-device model."
        case .notSupported:
            if canRunMLX {
                return "Apple Intelligence isn't supported on this iPhone. Pick an on-device model."
            } else {
                return "Nod needs a newer iPhone. Requires iPhone 15 Pro or newer, or 6 GB of memory."
            }
        }
    }
}

// MARK: - AFMUnavailableBanner
//
// Persistent banner shown when the user has existing chat history
// (messages non-empty) but AFM is unavailable on the current device.
// Primary trigger: iCloud backup restored from an AFM-capable device
// onto one that can't run it (iPhone 15 Pro → iPhone 15 base).
//
// Matches the existing `fallbackBanner` chrome EXACTLY:
// secondarySystemBackground fill, 12pt corner radius, info.circle icon
// in secondary, caption text. No colored left-border (that's on the AI
// slop blacklist). Intentionally different from `fallbackBanner` in
// one way: NOT dismissible by X — the only way to clear this banner
// is to switch engines (which resolves the underlying condition).
private struct AFMUnavailableBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Apple Intelligence isn't available on this iPhone.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Your conversation is safe. Tap the menu to pick an on-device model and keep chatting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Apple Intelligence isn't available on this iPhone. Your conversation is safe. Tap the menu to pick an on-device model and keep chatting.")
    }
}

#Preview {
    ChatView()
        .environmentObject(AppLockManager())
        .preferredColorScheme(.dark)
}

// MARK: - Post-commit pulse

/// Brief NodAccent underline that fades in-and-out across the input
/// field after a dictation transcript lands. Purely visual — catches
/// the user's eye so misheard words get noticed before tap-to-send.
///
/// Keyed on a Date trigger passed from ChatView; every new commit
/// replaces the date and re-triggers the animation via `onChange`.
private struct PostCommitPulse: View {
    let trigger: Date
    @State private var opacity: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Rectangle()
            .fill(Color("NodAccent"))
            .frame(maxWidth: .infinity)
            .frame(height: 2)
            .opacity(opacity)
            .onAppear { animate() }
            .onChange(of: trigger) { _, _ in animate() }
    }

    private func animate() {
        // Instant up, then gentle fade out over ~1.5s. Reduce-motion
        // users get the same signal minus the fade (still attention
        // without movement).
        if reduceMotion {
            opacity = 1
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                opacity = 0
            }
            return
        }
        opacity = 1
        withAnimation(.easeOut(duration: 1.5)) {
            opacity = 0
        }
    }
}
