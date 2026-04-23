// EmptyStateView.swift
// Shown when the conversation has zero messages (first launch, after clear).
//
// Visual: large version of the Nod face (app icon), doing a slow single blink
// every 4-5 seconds. Centered vertically above the input field. Headline:
// time-of-day aware ("Good morning", "I'm listening.", "How was today?", etc.).
// Body: one line of gentle guidance.
//
// The input field IS the CTA. No buttons, no "Get Started."

import SwiftUI

struct EmptyStateView: View {
    @State private var timer: Timer?
    @State private var blinkOn = false

    /// Recomputed each time the view appears. Not reactive — the empty
    /// state only exists before the first message is sent, so a user
    /// crossing a time boundary while staring at it is a non-issue.
    @State private var greeting: Greeting = Greeting.forNow()

    var body: some View {
        VStack(spacing: 24) {
            // Large Nod face (80pt) — eyes blink slowly.
            // NodMascot = canonical face (glimmer + oval eyes), same
            // geometry as the app icon. The blink is driven through
            // eyesClosed; the .animation modifier below carries the
            // easing down to NodMascot's scaleEffect.
            NodMascot(size: 80, eyesClosed: blinkOn)
                .animation(
                    .easeInOut(duration: NodMascotTokens.blinkDuration),
                    value: blinkOn
                )
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(greeting.headline)
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.primary)

                Text(greeting.subline)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(greeting.headline). \(greeting.subline)")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            greeting = Greeting.forNow()
            startBlinking()
        }
        .onDisappear { stopBlinking() }
    }

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

/// Time-of-day greeting variants. Copy stays restrained — Nod is a
/// companion, not a chirpy concierge. The subline is the same across
/// variants so the CTA stays consistent.
private struct Greeting {
    let headline: String
    let subline: String

    static func forNow(_ date: Date = Date()) -> Greeting {
        let hour = Calendar.current.component(.hour, from: date)
        let subline = "Type what's on your mind."
        switch hour {
        case 5..<11:
            return Greeting(headline: "Good morning.", subline: subline)
        case 11..<17:
            return Greeting(headline: "I'm listening.", subline: subline)
        case 17..<22:
            return Greeting(headline: "How was today?", subline: subline)
        default:
            // 22:00–04:59 — late night / early hours. Keep it gentle.
            return Greeting(headline: "Late night. I'm here.", subline: subline)
        }
    }
}

#Preview {
    EmptyStateView()
        .preferredColorScheme(.dark)
}
