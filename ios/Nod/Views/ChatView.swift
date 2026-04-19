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

struct ChatView: View {

    @StateObject private var store: ConversationStore
    @State private var inputText: String = ""
    @State private var nodTrigger: Int = 0
    @State private var isInferring: Bool = false
    @State private var showingSidebar: Bool = false
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

        // Opening the DB should never fail on a healthy device. If it does,
        // crash with a clear message — this is not a user-recoverable state.
        let db: MessageDatabase
        do {
            db = try MessageDatabase()
        } catch {
            fatalError("Nod: could not open conversation database: \(error)")
        }

        // Capture the holder (not a specific engine) so compression always
        // uses whichever engine is current when it fires — even if the user
        // switched between append and the compression task starting.
        self._store = StateObject(wrappedValue: ConversationStore(
            database: db,
            summarizer: { [holder] in holder.engine }
        ))
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
                    Button {
                        showingSidebar = true
                    } label: {
                        MiniNodFace()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open menu")
                }
            }
            .sheet(isPresented: $showingSidebar) {
                SidebarView(store: store, engineHolder: engineHolder) {
                    // User tapped "Start fresh" and confirmed. Reset any
                    // local in-flight state that isn't owned by the store.
                    isInferring = false
                }
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
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(store.messages) { msg in
                        MessageBubble(message: msg)
                            .id(msg.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
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

    @ViewBuilder
    private var qwenReadinessBar: some View {
        switch engineHolder.qwenLoadState {
        case .notLoaded, .ready:
            EmptyView()

        case .downloading(let fraction):
            readinessCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Downloading Qwen…")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text("\(Int(fraction * 100))%")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    ProgressView(value: fraction)
                        .tint(Color("NodAccent"))
                    Text("Nod runs the AI on your device. This one-time download is ~2.3 GB.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
        inputText = ""
        store.append(Message(role: .user, text: text))
        triggerNod()
        respond(to: text)
    }

    private func triggerNod() {
        nodTrigger &+= 1
        let haptic = UIImpactFeedbackGenerator(style: .light)
        haptic.impactOccurred()
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
                // Haptic on arrival. Lighter than send (soft tap, "something
                // landed for you"). Error uses a distinct warning pattern.
                if wasError {
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                } else {
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                }
            }
        }
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
        }
    }
}

#Preview {
    ChatView()
        .preferredColorScheme(.dark)
}
