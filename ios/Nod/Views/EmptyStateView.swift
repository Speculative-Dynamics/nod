// EmptyStateView.swift
// Shown when the conversation has zero messages (first launch, after clear).
//
// Visual: 80pt Nod face (NodMascotBlinker) slowly blinking. Centered
// vertically above the input field. Headline is time-of-day aware
// ("Good morning", "I'm listening.", "How was today?", etc.). Body is
// one line of gentle guidance.
//
// The input field IS the CTA. No buttons, no "Get Started."

import SwiftUI

struct EmptyStateView: View {
    /// Recomputed each time the view appears. Not reactive — the empty
    /// state only exists before the first message is sent, so a user
    /// crossing a time boundary while staring at it is a non-issue.
    @State private var greeting: Greeting = Greeting.forNow()

    var body: some View {
        VStack(spacing: 24) {
            // Large Nod face (80pt). NodMascotBlinker owns the blink
            // cadence and jitter — same implementation as the nav-bar
            // mascot, so two blinkers on screen stay naturally
            // desynced.
            NodMascotBlinker(size: 80)
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
        .onAppear { greeting = Greeting.forNow() }
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
