// ChatView.swift
// The one screen in Phase 1. Chat message list + text input + send button.
//
// Layout:
//   ┌─────────────────────────────────┐
//   │ 🟠                              │  nav bar: MiniNodFace (leading),
//   │                                 │           no title text
//   ├─────────────────────────────────┤
//   │   AI bubble (left-aligned)      │
//   │        User bubble (right)      │  scrolling message list
//   │   AI bubble                     │
//   │                                 │
//   ├─────────────────────────────────┤
//   │ ┌───────────────┐  ⭘  ↑         │  input bar: textfield +
//   │ │ Type what's … │                │             just-nod + send
//   │ └───────────────┘                │
//   └─────────────────────────────────┘

import SwiftUI

struct ChatView: View {

    @StateObject private var store: ConversationStore
    @State private var inputText: String = ""
    @State private var nodTrigger: Int = 0
    @State private var isInferring: Bool = false
    @FocusState private var inputFocused: Bool

    // FoundationModelsClient throws from init only if a prompt file is
    // missing from the bundle (build pipeline broken). Surfaced clearly in
    // the UI rather than silently degrading.
    //
    // The same engine instance handles BOTH listening responses (respond)
    // AND compression summarization (summarize). ConversationStore captures
    // it in its summarizer closure.
    private let engine: FoundationModelsClient?

    init() {
        let engine = try? FoundationModelsClient()
        self.engine = engine

        // Opening the DB should never fail on a healthy device. If it does,
        // crash with a clear message — this is not a user-recoverable state.
        let db: MessageDatabase
        do {
            db = try MessageDatabase()
        } catch {
            fatalError("Nod: could not open conversation database: \(error)")
        }

        self._store = StateObject(wrappedValue: ConversationStore(
            database: db,
            summarizer: { engine }
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

                inputBar
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        openSidebar()
                    } label: {
                        MiniNodFace()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open menu")
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
            .onChange(of: store.messages.count) { _, _ in
                if let last = store.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Type what's on your mind…", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .focused($inputFocused)
                .accessibilityLabel("Message")

            // "Just nod" button: lets the user get a silent acknowledgment
            // without typing. Always enabled — sometimes you don't have
            // words, you just want Nod to nod. Independent of send so it
            // works whether the input is empty or not.
            Button {
                justNod()
            } label: {
                Image(systemName: "circle.dotted")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Just nod — silent acknowledgment")

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
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isInferring
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        store.append(Message(role: .user, text: text))
        triggerNod()
        respond(to: text)
    }

    private func justNod() {
        store.append(Message(role: .nod))
        triggerNod()
        let haptic = UIImpactFeedbackGenerator(style: .medium)
        haptic.impactOccurred()
    }

    private func triggerNod() {
        nodTrigger &+= 1
        let haptic = UIImpactFeedbackGenerator(style: .light)
        haptic.impactOccurred()
    }

    /// Reserved for a future sidebar (settings, history, etc.). No-op today —
    /// tapping the mini face in the nav bar doesn't do anything yet.
    private func openSidebar() {
        // TODO: present sidebar sheet or navigation destination.
    }

    private func respond(to text: String) {
        guard let engine else {
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
            do {
                reply = try await engine.respond(to: text, context: context)
            } catch InferenceError.modelNotReady {
                reply = "Apple Intelligence isn't ready on this device. Check Settings → Apple Intelligence."
            } catch InferenceError.guardrailViolation {
                reply = "I'd rather not respond to that."
            } catch {
                reply = "Something went wrong. Try again."
            }
            await MainActor.run {
                store.replaceLastAssistantMessage(with: reply)
                isInferring = false
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
