// Soft.swift
// The "Soft" look: a warm messenger with a friend. Colours live in the
// asset catalog (Soft*.colorset), each with a light and a dark value,
// so they follow the system appearance and the in-app Theme setting
// without any code switching on colorScheme.
//
// Type is SF Pro Rounded via `.fontDesign(.rounded)` at the root, which
// keeps Dynamic Type and matches the mascot's rounded corners.

import SwiftUI

enum Soft {
    /// Screen background: warm off-white / warm near-black.
    static let background = Color("SoftBackground")
    /// Nod's bubbles, the composer, cards and chips.
    static let surface = Color("SoftSurface")
    /// Hairlines and card borders (dark mode relies on these instead of shadows).
    static let hairline = Color("SoftHairline")
    /// The user's own bubbles: the accent, softened.
    static let userBubble = Color("SoftUserBubble")
    /// Quiet fills: pills, the disabled send button.
    static let chip = Color("SoftChip")
    /// Primary text.
    static let ink = Color("SoftInk")
    /// Secondary text: dates, captions, status.
    static let muted = Color("SoftMuted")
    /// Placeholders and typing dots.
    static let faint = Color("SoftFaint")
    /// The brand orange (already light/dark in the catalog).
    static let accent = Color("NodAccent")

    /// Bubble shapes: rounded, with the corner nearest the speaker tucked in.
    static func userBubbleShape() -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20,
                               bottomTrailingRadius: 6, topTrailingRadius: 20,
                               style: .continuous)
    }

    static func nodBubbleShape() -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 6,
                               bottomTrailingRadius: 20, topTrailingRadius: 20,
                               style: .continuous)
    }
}

extension View {
    /// The light shadow that lifts Soft surfaces off the background in
    /// light mode. In dark mode a hairline border does that job instead.
    func softLift<S: Shape>(_ colorScheme: ColorScheme, in shape: S) -> some View {
        self
            .shadow(color: colorScheme == .dark ? .clear : Color.black.opacity(0.06), radius: 2, y: 1)
            .overlay {
                if colorScheme == .dark {
                    shape.stroke(Soft.hairline, lineWidth: 1)
                }
            }
    }
}

/// Lets a view pick a label style at runtime.
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView

    init<S: LabelStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}
