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
    @State private var inputText: String = ""
    @State private var nodTrigger: Int = 0
    @State private var isInferring: Bool = false
    @State private var showingSidebar: Bool = false
    /// Controls the "Pause download?" alert triggered by Cancel on the
    /// downloading card. Splitting it into its own state avoids races
    /// where a fast-fingered user could double-tap.
    @State private var showingCancelDownloadAlert: Bool = false
    // The ID of the bottom-most fully-visible message. Bound to the
    // ScrollView via .scrollPosition. When user scrolls manually, this
    // updates; we use it to decide whether auto-scroll should follow new
    // messages or leave the user reading history undisturbed.
    @State private var scrollAnchorId: UUID?
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

        // Capture the holder (not a specific engine) so compression always
        // uses whichever engine is current when it fires — even if the user
        // switched between append and the compression task starting.
        self._store = StateObject(wrappedValue: ConversationStore(
            database: db,
            summarizer: { [holder] in holder.engine }
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
        NavigationStack {
            VStack(spacing: 0) {
                if store.messages.isEmpty {
                    EmptyStateView()
                } else {
                    messageList
                }

                if isInferring {
                    // While Nod is thinking, the eyes do a left-right-blink
                    // loop so the user feels an active presence rather than
                    // staring at static eyes.
                    NodAnimation(trigger: nodTrigger, isThinking: true)
                        .padding(.bottom, 8)
                        .transition(.opacity)
                }

                // Qwen is the only engine that has a pre-send readiness
                // step. AFM is ready as soon as it exists.
                if engineHolder.preference == .qwen {
                    qwenReadinessBar
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .animation(.easeInOut(duration: 0.25), value: engineHolder.qwenLoadState)
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
                SidebarView(store: store, engineHolder: engineHolder) {
                    // User tapped "Start fresh" and confirmed. Reset any
                    // local in-flight state that isn't owned by the store.
                    isInferring = false
                    // Warning haptic confirms the destructive action landed.
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                }
            }
            // "Pause download?" confirmation. Default action is "Keep
            // downloading" (safer on accidental tap). "Pause" is .cancel
            // role (not .destructive) because Pause is genuinely
            // reversible — resume data is persisted and the user can
            // resume whenever. Destructive-red would miscommunicate.
            .alert("Pause download?", isPresented: $showingCancelDownloadAlert) {
                Button("Keep downloading", role: nil) { }
                Button("Pause", role: .cancel) {
                    engineHolder.cancelQwenDownload()
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                }
            } message: {
                Text("Your progress is saved — you can resume anytime.")
            }
            // Keep the screen awake while Qwen is mid-download or mid-load.
            // A foreground URLSession dies when iOS suspends the app after
            // screen lock, and a 2 GB model takes 5+ minutes — a default
            // screen timeout would kill the transfer. Idle-timer-disabled
            // is the standard iOS affordance for "user is watching a
            // long-running operation." Released back to the system once
            // the model is ready or the transfer fails, so we don't drain
            // the battery during normal chat.
            .onChange(of: engineHolder.qwenLoadState) { _, newValue in
                // Keep the screen awake while bytes are actively moving OR
                // MLX is loading. In waiting/paused states the download
                // isn't progressing, so a sleeping screen costs us nothing.
                switch newValue {
                case .downloading, .loading:
                    UIApplication.shared.isIdleTimerDisabled = true
                case .ready, .failed, .notLoaded,
                     .waitingForNetwork, .waitingForWifi, .paused:
                    UIApplication.shared.isIdleTimerDisabled = false
                }
            }
            .onDisappear {
                // Belt-and-suspenders: if the view goes away mid-download
                // (shouldn't happen — ChatView is the root — but defensive),
                // release the idle lock so we don't drain battery forever.
                UIApplication.shared.isIdleTimerDisabled = false
            }
            // Swipe gestures to manage the keyboard without reaching for the
            // input field: swipe up anywhere to open, swipe down to close.
            // Uses simultaneousGesture so it doesn't steal events from the
            // scroll view's own drag.
            .simultaneousGesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        let dy = value.translation.height
                        let dx = abs(value.translation.width)
                        // Only react to primarily-vertical swipes
                        guard abs(dy) > dx else { return }
                        if dy > 40 {
                            inputFocused = false    // swipe down → dismiss keyboard
                        } else if dy < -40 {
                            inputFocused = true     // swipe up → open keyboard
                        }
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
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(store.messages.enumerated()), id: \.element.id) { index, msg in
                        let prev = index > 0 ? store.messages[index - 1] : nil
                        MessageBubble(message: msg)
                            .id(msg.id)
                            .padding(.top, Self.topPadding(for: msg, prev: prev, isFirst: index == 0))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                // Breathing room between the last message and whatever sits
                // directly below: the download readiness card or the input
                // bar. Without this, the final bubble visually collides
                // with the chrome underneath.
                .padding(.bottom, 16)
            }
            // Interactive keyboard dismiss: dragging down on messages pulls
            // the keyboard down with the finger, iOS-native feel.
            .scrollDismissesKeyboard(.interactively)
            // Track which message is at the bottom of the visible area so
            // we can decide whether the user is "pinned to bottom" or
            // "reading history" when new messages arrive.
            .scrollPosition(id: $scrollAnchorId, anchor: .bottom)
            .onChange(of: store.messages.count) { oldCount, newCount in
                guard newCount > 0 else { return }
                let msgs = store.messages
                let newLastId = msgs.last?.id
                // The message that was previously the bottom of the list
                // (i.e., what the user was looking at if they were at the
                // bottom before this new one arrived).
                let prevLastId = msgs.count >= 2 ? msgs[msgs.count - 2].id : nil

                // Follow the new message IF the user was at the bottom, or
                // if this is the very first message ever, or if the
                // scrollPosition binding hasn't had a chance to sync yet
                // (scrollAnchorId == nil). If they scrolled up to read
                // history, leave them alone.
                let wasAtBottom = scrollAnchorId == prevLastId
                    || prevLastId == nil
                    || scrollAnchorId == nil
                if wasAtBottom, let newLastId {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(newLastId, anchor: .bottom)
                    }
                    // Belt-and-suspenders: scrollPosition binding SHOULD
                    // update after proxy.scrollTo, but we've seen enough
                    // SwiftUI scroll quirks to not trust it implicitly.
                    // Explicit sync keeps subsequent was-at-bottom checks
                    // correct.
                    scrollAnchorId = newLastId
                }
            }
            // When the in-flight assistant message's text fills in, also
            // follow to bottom (if we were there). Count doesn't change on
            // replaceLastAssistantMessage, so we need a separate trigger.
            .onChange(of: store.messages.last?.text) { _, _ in
                guard let newLastId = store.messages.last?.id else { return }
                // Was-at-bottom check: scrollAnchor still points at the
                // last message (since count hasn't changed). If it matches,
                // we're at bottom. Also accept nil anchor as "at bottom"
                // because scrollPosition may not have settled yet for the
                // fresh message.
                if scrollAnchorId == newLastId || scrollAnchorId == nil {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(newLastId, anchor: .bottom)
                    }
                    scrollAnchorId = newLastId
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            // The text field handles both typing AND dictation — iOS's
            // built-in keyboard has a mic button in the bottom-right that
            // dictates into any focused text field, on-device on
            // Apple-Intelligence-capable devices. We don't need our own
            // mic button or mic-handling code.
            TextField("Type what's on your mind…", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .focused($inputFocused)
                .accessibilityLabel("Message")
                // No .submitLabel(.send)/.onSubmit here: with axis: .vertical
                // and lineLimit(1...5), Return inserts a newline (iMessage
                // behavior) and onSubmit never fires. A "send" label would
                // lie. Hardware keyboards get Cmd+Return via the shortcut
                // button in .background above.

            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .foregroundStyle(sendEnabled ? Color("NodAccent") : .secondary)
            }
            .disabled(!sendEnabled)
            .accessibilityLabel("Send message")
        }
    }

    private var sendEnabled: Bool {
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard !isInferring else { return false }
        if engineHolder.preference == .qwen {
            if case .ready = engineHolder.qwenLoadState { return true }
            return false
        }
        return true
    }

    // MARK: - Qwen readiness bar
    //
    // All download-ish states reuse the same `readinessCard` chrome —
    // only headers, metadata, and actions vary. The state taxonomy:
    //
    //   .downloading(m)           → animated bar, live bytes/speed/ETA, Cancel
    //   .waitingForNetwork(m)     → frozen bar, "we'll pick up when you're online", Cancel
    //   .waitingForWifi(m)        → frozen bar, "Use cellular this time" + Cancel
    //   .paused(m)                → frozen bar, centered [Resume download] button
    //   .loading                  → spinner + "Loading Qwen into memory…"
    //   .failed(msg)              → typed error title + body + Try again
    //   .notLoaded / .ready       → card hidden
    //
    // Variant B layout: stacked hierarchy. Bytes get their own line
    // (the primary "how far along am I" signal). Speed + ETA share the
    // second metadata line in secondary. Cancel is bottom-right, plain
    // text, not a button.
    @ViewBuilder
    private var qwenReadinessBar: some View {
        switch engineHolder.qwenLoadState {
        case .notLoaded, .ready:
            EmptyView()

        case .downloading(let metrics):
            readinessCard {
                downloadingCardContent(metrics: metrics, isActive: true)
            }

        case .waitingForNetwork(let metrics):
            readinessCard {
                waitingCardContent(
                    metrics: metrics,
                    header: "Waiting for the network…",
                    body: "We'll pick up when you're back online.",
                    showCellularLink: false
                )
            }

        case .waitingForWifi(let metrics):
            readinessCard {
                waitingCardContent(
                    metrics: metrics,
                    header: "Waiting for Wi-Fi…",
                    body: "Nod will continue when you're back on Wi-Fi.",
                    showCellularLink: true
                )
            }

        case .paused(let metrics):
            readinessCard {
                pausedCardContent(metrics: metrics)
            }

        case .loading:
            readinessCard {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading Qwen into memory…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

        case .failed:
            readinessCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text(qwenFailureTitle)
                        .font(.subheadline.weight(.medium))
                    Text(qwenFailureBody)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Try again") {
                        engineHolder.retryQwenLoad()
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color("NodAccent"))
                    .padding(.top, 2)
                }
            }
        }
    }

    /// Active downloading card: live bytes + speed + ETA + Cancel.
    @ViewBuilder
    private func downloadingCardContent(metrics: DownloadMetrics, isActive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Downloading Qwen…")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Int(metrics.fraction * 100))%")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            ProgressView(value: metrics.fraction)
                .tint(Color("NodAccent"))

            // Line 1: byte count — the primary "how far along" signal.
            Text(formatByteProgress(written: metrics.bytesWritten,
                                     total: metrics.totalBytes))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.primary)

            // Line 2: speed · ETA (caption secondary). Hidden until we
            // have a stable rate reading; otherwise we'd show "0 MB/s"
            // for the first second which looks like something's wrong.
            if isActive, let subtitle = formatSpeedAndETA(metrics: metrics) {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            // Cancel link. Plain text, right-aligned. Pressing it opens
            // the "Pause download?" confirmation alert rather than
            // cancelling immediately.
            HStack {
                Spacer()
                Button("Cancel") {
                    showingCancelDownloadAlert = true
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
            }
        }
    }

    /// Waiting-for-something card. Same chrome as downloading, bar frozen,
    /// rate/ETA line hidden. Optionally shows "Use cellular this time".
    @ViewBuilder
    private func waitingCardContent(
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

            Text(formatByteProgress(written: metrics.bytesWritten,
                                     total: metrics.totalBytes))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.primary)

            Text(body)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                if showCellularLink {
                    Button("Use cellular this time") {
                        engineHolder.useCellularThisTime()
                    }
                    .font(.subheadline)
                    .foregroundStyle(Color("NodAccent"))
                    .buttonStyle(.plain)
                }
                Spacer()
                Button("Cancel") {
                    showingCancelDownloadAlert = true
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
            }
        }
    }

    /// Paused card: user tapped Cancel earlier; resume data on disk.
    /// Presents a filled [Resume download] button, centered, NodAccent
    /// fill — a positive action deserves visual weight that a link wouldn't.
    @ViewBuilder
    private func pausedCardContent(metrics: DownloadMetrics) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Qwen download paused")
                .font(.subheadline.weight(.medium))

            ProgressView(value: metrics.fraction)
                .tint(Color("NodAccent"))

            Text("\(formatByteProgress(written: metrics.bytesWritten, total: metrics.totalBytes)) downloaded")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button {
                    engineHolder.resumeQwenDownload()
                } label: {
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

    // MARK: - Download formatters

    /// "721 MB of 2.3 GB". Uses ByteCountFormatter in the friendlier
    /// decimal style (MB, GB) rather than binary (MiB, GiB) because that
    /// matches Apple's own App Store / iCloud sizing copy.
    private func formatByteProgress(written: Int64, total: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useMB, .useGB]
        f.includesUnit = true
        return "\(f.string(fromByteCount: written)) of \(f.string(fromByteCount: total))"
    }

    /// "3.4 MB/s · about 8 min remaining". Returns nil when we don't have
    /// stable data yet — the caller then shows only the byte-count line.
    private func formatSpeedAndETA(metrics: DownloadMetrics) -> String? {
        let rate = metrics.bytesPerSecond
        guard rate > 0 else { return nil }

        let rateFormatter = ByteCountFormatter()
        rateFormatter.countStyle = .file
        rateFormatter.allowedUnits = [.useKB, .useMB]
        rateFormatter.includesUnit = true
        let rateString = "\(rateFormatter.string(fromByteCount: Int64(rate)))/s"

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

    /// Shared card chrome for the readiness states so we only edit one place
    /// when the look changes.
    @ViewBuilder
    private func readinessCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Pull apart the `.failed(String)` payload to decide what to show.
    /// We match on the raw description rather than re-typing because
    /// QwenClient stores the error's description in the state, not the
    /// original Error. Crude but serviceable.
    private var qwenFailureTitle: String {
        guard case .failed(let msg) = engineHolder.qwenLoadState else { return "Qwen failed to load" }
        if msg.contains("downloadFailedNoNetwork") {
            return "Can't reach the download server"
        }
        if msg.contains("downloadFailedDiskFull") {
            return "Not enough space for Qwen"
        }
        return "Qwen failed to load"
    }

    private var qwenFailureBody: String {
        guard case .failed(let msg) = engineHolder.qwenLoadState else { return "Tap Try again below." }
        if msg.contains("downloadFailedNoNetwork") {
            return "Connect to Wi-Fi and try again. The download is ~2.3 GB."
        }
        if msg.contains("downloadFailedDiskFull") {
            return "Free up ~3 GB on your device, then try again."
        }
        return "Something went wrong. Try again, or switch back to Apple Intelligence in the menu."
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
        // Insert an empty assistant message. Filtered out of context we
        // build for the model; filled with the reply when it arrives.
        store.append(Message(role: .assistant, text: ""))
        let context = store.contextForInference()

        Task {
            let reply: String
            var wasError = false
            do {
                let rawReply = try await engine.respond(to: text, context: context)
                // Guard against empty replies (e.g. Qwen burns all its tokens
                // inside a <think> block and never emits a final response).
                // Without this, the placeholder message stays empty and the
                // UI shows typing-dots indefinitely with no way to recover.
                if rawReply.isEmpty {
                    reply = "Something went wrong. Try again."
                    wasError = true
                } else {
                    reply = rawReply
                }
            } catch InferenceError.modelNotReady {
                // Engine-specific: AFM is settings-gated; Qwen is download-gated.
                switch EnginePreferenceStore.current {
                case .apple:
                    reply = "Apple Intelligence isn't ready on this device. Check Settings → Apple Intelligence."
                case .qwen:
                    reply = "Qwen isn't ready yet. The model still needs to finish downloading."
                }
                wasError = true
            } catch InferenceError.guardrailViolation {
                reply = "I'd rather not respond to that."
                wasError = true
            } catch {
                reply = "Something went wrong. Try again."
                wasError = true
            }
            await MainActor.run {
                store.replaceLastAssistantMessage(with: reply)
                isInferring = false
                // Haptic on arrival. Soft tap ("something landed for you")
                // for a real reply; warning pattern for an error so the
                // user feels the difference without reading.
                if wasError {
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                } else {
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                }
            }
        }
    }

    // MARK: - Message spacing

    /// Top padding between message bubbles. Tight for same-sender follow-ups
    /// so a block of thought reads as one block; wider when the speaker
    /// changes so the exchange has visible rhythm. Nod-blink rows get a bit
    /// more breathing room because the eyes are visually heavy.
    private static func topPadding(for msg: Message, prev: Message?, isFirst: Bool) -> CGFloat {
        if isFirst { return 0 }
        guard let prev else { return 0 }
        if msg.role == .nod || prev.role == .nod { return 16 }
        return msg.role == prev.role ? 4 : 14
    }
}

// MARK: - MessageBubble

struct MessageBubble: View {
    let message: Message

    @State private var nodTriggerForThisBubble: Int = 0

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 40)
                bubble(color: Color(.tertiarySystemFill))
            } else if message.role == .assistant {
                bubble(color: Color(.secondarySystemBackground))
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

#Preview {
    ChatView()
        .environmentObject(AppLockManager())
        .preferredColorScheme(.dark)
}
