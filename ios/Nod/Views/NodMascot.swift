// NodMascot.swift
// The canonical Nod face. Every in-app rendering of the mascot —
// onboarding, nav bar, splash, lock screen, empty state — sources
// from the views and tokens in this file. If you find yourself
// hardcoding a color, corner radius, or eye proportion somewhere
// else in the app, put it in NodMascotTokens instead.
//
// Three building blocks so callers can compose:
//
//   NodMascotTokens   — every constant, sourced from Icon-1024.png
//   NodMascotBody     — just the orange rounded square
//   NodMascotEye      — one eye (oval + glimmer), sized to face
//   NodMascot         — full face (body + eye-pair + blink)
//
// Most callers just want NodMascot(size:eyesClosed:). SplashView
// animates the body and eyes on independent timelines, so it
// composes NodMascotBody + NodMascotEye directly.
//
// Not used for: NodAnimation.swift, which is the floating-eyes beat
// inside chat bubbles — a different character moment, orange-on-
// transparent, correctly separate.

import SwiftUI

// MARK: - Tokens

/// Canonical design tokens for the Nod mascot. Values come from
/// sampling Icon-1024.png directly (the eye fill was confirmed as
/// #1a1a1a by pixel-sampling the PNG). Change these only if the
/// icon itself changes — the whole app will follow.
enum NodMascotTokens {

    // MARK: Colors

    /// Eye fill. `#1a1a1a` ≈ `(0.102, 0.102, 0.102)` linear. Pulled
    /// from pixel-sampling the app icon. Not pure black on purpose —
    /// 10% gray reads as "alive" where pure black reads as mechanical.
    static let eyeColor = Color(red: 0.102, green: 0.102, blue: 0.102)

    /// Body color. Asset-catalog sourced so theme variants (if ever)
    /// follow automatically.
    static let bodyColor = Color("NodAccent")

    /// Glimmer highlight. Pure white — the single bright beat that
    /// gives the face personality.
    static let glimmerColor = Color.white

    // MARK: Geometry — all ratios are fractions of the face width

    /// Rounded-square corner radius ratio. 0.2237 ≈ the iOS icon
    /// superellipse approximation at this particular face shape.
    static let cornerRatio: CGFloat = 0.2237

    /// Eye width as fraction of face. ≈ 13% gives two ovals that
    /// read as eyes at every scale from 24pt to 1024pt.
    static let eyeWidthRatio: CGFloat = 0.13

    /// Eye height as fraction of face. Aspect ≈ 1.7 (taller than wide)
    /// — the upright oval is what makes Nod look like Nod.
    static let eyeHeightRatio: CGFloat = 0.22

    /// HStack spacing between eye frames (edge-to-edge, not center-
    /// to-center).
    static let eyeSpacingRatio: CGFloat = 0.19

    /// White glimmer diameter as fraction of face.
    static let glimmerSizeRatio: CGFloat = 0.035

    /// Glimmer offset from eye center, as fraction of eye dimension.
    /// Upper-right placement = light-source-upper-left convention.
    static let glimmerOffsetXRatio: CGFloat = 0.15   // right of center (× eye width)
    static let glimmerOffsetYRatio: CGFloat = -0.25  // above center (× eye height)

    // MARK: Glimmer scale-aware fade

    /// Face size at and above which the glimmer is rendered at full
    /// opacity.
    static let glimmerFullSize: CGFloat = 40

    /// Face size at and below which the glimmer is rendered at zero
    /// opacity. Between here and `glimmerFullSize`, opacity ramps
    /// linearly. Below the floor, a sub-pixel dot is rendering
    /// noise, not personality.
    static let glimmerFadeSize: CGFloat = 24

    // MARK: Blink

    /// Vertical scale multiplier when eyes are closed. ~0.1 leaves
    /// a thin slit rather than collapsing to a line — reads as a
    /// blink, not a vanish.
    static let blinkClosedScaleY: CGFloat = 0.1

    /// Standard blink easing duration. Same beat used in nav-bar
    /// idle blinks, empty-state slow blinks, and the splash wake-up
    /// blink, so the character has one cadence across the app.
    static let blinkDuration: Double = 0.2
}

// MARK: - Body (orange rounded square)

/// The mascot's body. Just the orange rounded square, no eyes.
/// Expose as its own view so SplashView can animate body size
/// independently of the eyes fading in.
struct NodMascotBody: View {
    let size: CGFloat

    var body: some View {
        RoundedRectangle(
            cornerRadius: size * NodMascotTokens.cornerRatio,
            style: .continuous
        )
        .fill(NodMascotTokens.bodyColor)
        .frame(width: size, height: size)
    }
}

// MARK: - Eye (single oval + glimmer)

/// A single Nod eye with glimmer, sized relative to the parent face.
/// All eye renderings across the app pull from this view — no one
/// else should hand-build an Ellipse and a Circle.
struct NodMascotEye: View {
    /// Size of the parent face. Eye dimensions and glimmer are all
    /// derived from this, so the character stays on-icon at every scale.
    let faceSize: CGFloat

    var body: some View {
        ZStack {
            Ellipse()
                .fill(NodMascotTokens.eyeColor)

            Circle()
                .fill(NodMascotTokens.glimmerColor)
                .frame(
                    width: faceSize * NodMascotTokens.glimmerSizeRatio,
                    height: faceSize * NodMascotTokens.glimmerSizeRatio
                )
                .offset(
                    x: faceSize * NodMascotTokens.eyeWidthRatio
                        * NodMascotTokens.glimmerOffsetXRatio,
                    y: faceSize * NodMascotTokens.eyeHeightRatio
                        * NodMascotTokens.glimmerOffsetYRatio
                )
                .opacity(glimmerOpacity)
        }
        .frame(
            width: faceSize * NodMascotTokens.eyeWidthRatio,
            height: faceSize * NodMascotTokens.eyeHeightRatio
        )
    }

    /// Linear fade between `glimmerFullSize` (1.0) and `glimmerFadeSize`
    /// (0.0). See token docs.
    private var glimmerOpacity: Double {
        let upper = NodMascotTokens.glimmerFullSize
        let lower = NodMascotTokens.glimmerFadeSize
        if faceSize >= upper { return 1.0 }
        if faceSize <= lower { return 0.0 }
        return Double((faceSize - lower) / (upper - lower))
    }
}

// MARK: - Full mascot (body + eye-pair)

/// Full canonical face. Body + two eyes with optional blink.
/// This is what most callers want: static face → pass `size`, blinking
/// face → pass `size` and bind `eyesClosed` to a boolean your parent
/// flips on a timer (see MiniNodFace).
struct NodMascot: View {
    var size: CGFloat = 88
    /// Flip to squash the eyes into a blink. Drive this from a parent
    /// view's animation state (see MiniNodFace, EmptyStateView).
    var eyesClosed: Bool = false

    var body: some View {
        ZStack {
            NodMascotBody(size: size)

            HStack(spacing: size * NodMascotTokens.eyeSpacingRatio) {
                NodMascotEye(faceSize: size)
                NodMascotEye(faceSize: size)
            }
            .scaleEffect(
                y: eyesClosed ? NodMascotTokens.blinkClosedScaleY : 1.0,
                anchor: .center
            )
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 24) {
        NodMascot(size: 120) // App-icon scale
        NodMascot(size: 96)  // Lock screen
        NodMascot(size: 88)  // Onboarding hero
        NodMascot(size: 80)  // Empty state
        NodMascot(size: 32)  // Nav bar (glimmer fades)
        NodMascot(size: 24)  // Below threshold
    }
    .padding()
    .preferredColorScheme(.dark)
}
