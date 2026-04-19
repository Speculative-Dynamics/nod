// EmptyStateView.swift
// Shown when the conversation has zero messages (first launch, after clear).
//
// Visual: large version of the Nod face (app icon), doing a slow single blink
// every 4-5 seconds. Centered vertically above the input field. Headline:
// "I'm listening." Body: one line of gentle guidance.
//
// The input field IS the CTA. No buttons, no "Get Started."

import SwiftUI

struct EmptyStateView: View {
    @State private var blinkTrigger: Int = 0
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 24) {
            // Large Nod face (80pt) — eyes blink slowly.
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color("NodAccent"))
                    .frame(width: 80, height: 80)

                HStack(spacing: 14) {
                    Ellipse()
                        .fill(Color.black)
                        .frame(width: 14, height: 20)
                    Ellipse()
                        .fill(Color.black)
                        .frame(width: 14, height: 20)
                }
                .scaleEffect(y: blinkOn ? 0.1 : 1.0, anchor: .center)
                .animation(.easeInOut(duration: 0.2), value: blinkOn)
            }
            .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("I'm listening.")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.primary)

                Text("Type what's on your mind, or tap the mic to speak.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Nod is listening. Type what's on your mind, or tap the mic to speak.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { startBlinking() }
        .onDisappear { stopBlinking() }
    }

    @State private var blinkOn = false

    private func startBlinking() {
        timer = Timer.scheduledTimer(withTimeInterval: 4.5, repeats: true) { _ in
            Task { @MainActor in
                blinkOn = true
                try? await Task.sleep(for: .milliseconds(200))
                blinkOn = false
            }
        }
    }

    private func stopBlinking() {
        timer?.invalidate()
        timer = nil
    }
}

#Preview {
    EmptyStateView()
        .preferredColorScheme(.dark)
}
