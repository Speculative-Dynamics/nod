// ChatView.swift
// The one screen in Phase 1. Chat message list + text input + send button.
//
// Layout:
//   ┌─────────────────────────────────┐
//   │ ◀ Nod              ⚙           │  nav bar
//   ├─────────────────────────────────┤
//   │   AI bubble (left-aligned)      │
//   │        User bubble (right)      │  scrolling message list
//   │   AI bubble                     │
//   │                                 │
//   ├─────────────────────────────────┤
//   │ ┌───────────────┐  🎤  ↑        │
//   │ │ Type or tap…  │                │  input bar: textfield + mic + send
//   │ └───────────────┘                │
//   └─────────────────────────────────┘

import SwiftUI

struct ChatView: View {

    @StateObject private var store = ConversationStore()
    @State private var inputText: String = ""
    @State private var nodTrigger: Int = 0
    @State private var isInferring: Bool = false
    @FocusState private var inputFocused: Bool

    // FoundationModelsClient never fails to init anymore — it has an embedded
    // fallback prompt if the resource file isn't found. Kept optional for the
    // future when we swap to Qwen and init can legitimately fail.
    private let engine: InferenceEngine = FoundationModelsClient()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if store.messages.isEmpty {
                    EmptyStateView()
                } else {
                    messageList
                }

                if isInferring {
                    NodAnimation(trigger: nodTrigger)
                        .padding(.bottom, 8)
                        .transition(.opacity)
                }

                inputBar
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
            .navigationTitle("Nod")
            .navigationBarTitleDisplayMode(.inline)
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
            TextField("Type or tap the mic…", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .focused($inputFocused)
                .accessibilityLabel("Message")

            Button {
                // TODO day 5-6: wire Transcriber here.
            } label: {
                Image(systemName: "mic.circle.fill")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Dictate with microphone")
            .disabled(true)  // day 5-6 feature

            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .foregroundStyle(sendEnabled ? Color("NodAccent") : .secondary)
            }
            .disabled(!sendEnabled)
            .accessibilityLabel("Send message")
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.6).onEnded { _ in
                    justNod()
                }
            )
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

    private func respond(to text: String) {
        isInferring = true
        // Insert an empty assistant message we'll fill as tokens stream in.
        store.append(Message(role: .assistant, text: ""))
        let context = store.contextWindow

        Task {
            do {
                let stream = try await engine.respond(to: text, context: context)
                var buffer = ""
                for await token in stream {
                    buffer += token
                    await MainActor.run {
                        store.replaceLastAssistantMessage(with: buffer)
                    }
                }
            } catch InferenceError.modelNotReady {
                await MainActor.run {
                    store.replaceLastAssistantMessage(with: "Apple Intelligence isn't ready on this device. Check Settings → Apple Intelligence.")
                }
            } catch {
                await MainActor.run {
                    store.replaceLastAssistantMessage(with: "Something went wrong. Try again.")
                }
            }
            await MainActor.run { isInferring = false }
        }
    }
}

// MARK: - MessageBubble

struct MessageBubble: View {
    let message: Message

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 40)
                bubble(color: Color(.tertiarySystemFill), alignment: .trailing)
            } else if message.role == .assistant {
                bubble(color: Color(.secondarySystemBackground), alignment: .leading)
                Spacer(minLength: 40)
            } else {
                // .nod — show only a centered inline blink, no bubble.
                Spacer()
                NodAnimation(trigger: 0)
                    .accessibilityLabel("Nod acknowledged")
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func bubble(color: Color, alignment: HorizontalAlignment) -> some View {
        if message.text.isEmpty && message.role == .assistant {
            // In-progress: show typing-dots placeholder instead of empty bubble.
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
