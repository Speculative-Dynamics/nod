// EmptyStateView.swift
// What a new or freshly cleared conversation shows: a time-of-day
// greeting and a few starters for the blank-page moment. Tapping a
// starter fills the message field (it doesn't send), so the person can
// change it or keep typing. Privacy is said once, in the header's
// "Private" pill, so it isn't repeated here.
//
// Full Dynamic Type + VoiceOver support.

import SwiftUI

struct EmptyStateView: View {
    /// Called with the starter's text when one is tapped.
    var onStarter: (String) -> Void = { _ in }

    @State private var greeting: Greeting = Greeting.forNow()
    @Environment(\.colorScheme) private var colorScheme

    private static let starters = [
        "I had a rough day",
        "Something's on my mind",
        "I just need to vent",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(greeting.headline)
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(Soft.ink)
                    Text(greeting.subline)
                        .font(.title3)
                        .foregroundStyle(Soft.muted)
                }
                .accessibilityElement(children: .combine)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Self.starters, id: \.self) { starter in
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            onStarter(starter)
                        } label: {
                            Text(starter)
                                .font(.body.weight(.medium))
                                .foregroundStyle(Soft.ink)
                                .multilineTextAlignment(.leading)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 12)
                                // Rounded rectangle, not a capsule, so a
                                // starter that wraps at large text keeps
                                // a calm shape.
                                .background(Soft.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                                .softLift(colorScheme, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Puts this in the message field")
                    }
                }
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerRelativeFrame(.vertical, alignment: .center)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onAppear { greeting = Greeting.forNow() }
    }
}

/// Time-of-day greeting. Copy stays restrained: Nod is a companion,
/// not a chirpy concierge.
private struct Greeting {
    let headline: String
    let subline: String

    static func forNow(_ date: Date = Date()) -> Greeting {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<11:
            return Greeting(headline: "Good morning.", subline: "How are you, really?")
        case 11..<17:
            return Greeting(headline: "I'm listening.", subline: "What's going on?")
        case 17..<22:
            return Greeting(headline: "How was today?", subline: "Tell me about it.")
        default:
            return Greeting(headline: "Late night. I'm here.", subline: "What's keeping you up?")
        }
    }
}

#Preview {
    EmptyStateView()
        .background(Soft.background)
        .fontDesign(.rounded)
}
