// NodMascot.swift
// The canonical in-app Nod face. THIS view mirrors Icon-1024.png —
// users should see the same character on the springboard, in onboarding,
// and in the nav bar. Single source of truth for "Nod's face."
//
// If you need Nod to blink or animate, wrap this view and drive
// `eyesClosed` (that's what MiniNodFace does).
//
// Not used for: NodAnimation.swift, which is the floating-eyes beat
// inside chat bubbles (no face, context-adaptive color).

import SwiftUI

struct NodMascot: View {
    var size: CGFloat = 88
    /// Set true to squash the eyes into a blink. Drive this from a
    /// parent view's animation state (see MiniNodFace).
    var eyesClosed: Bool = false

    // Proportions pulled from Icon-1024.png. Any drift here is drift
    // from the app icon — keep these locked unless the icon changes too.
    // Eye dimensions + glimmer live in NodMascotEye.
    private let cornerRatio: CGFloat = 0.2237
    private let eyeSpacingRatio: CGFloat = 0.19

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * cornerRatio, style: .continuous)
                .fill(Color("NodAccent"))

            HStack(spacing: size * eyeSpacingRatio) {
                NodMascotEye(faceSize: size)
                NodMascotEye(faceSize: size)
            }
            .scaleEffect(y: eyesClosed ? 0.1 : 1.0, anchor: .center)
        }
        .frame(width: size, height: size)
    }
}

/// A single Nod eye with glimmer, sized relative to an implied face.
/// Exposed as its own view so SplashView (and anything else that
/// animates the eye independently of the body) can reuse the
/// canonical geometry instead of re-inventing it.
struct NodMascotEye: View {
    /// Size of the parent face. Eye dimensions and glimmer are all
    /// derived from this so the character stays on-icon at every scale.
    let faceSize: CGFloat

    private let eyeWidthRatio: CGFloat = 0.13
    private let eyeHeightRatio: CGFloat = 0.22
    private let glimmerSizeRatio: CGFloat = 0.035

    var body: some View {
        ZStack {
            Ellipse()
                .fill(Color(red: 0.08, green: 0.08, blue: 0.08))

            // The glimmer. Upper-right of eye center, light-source-
            // upper-left convention. Fades below 40pt face size because
            // at small sizes it's either invisible or anti-aliases into
            // a blur.
            Circle()
                .fill(Color.white)
                .frame(width: faceSize * glimmerSizeRatio,
                       height: faceSize * glimmerSizeRatio)
                .offset(x: faceSize * eyeWidthRatio * 0.15,
                        y: -faceSize * eyeHeightRatio * 0.25)
                .opacity(glimmerOpacity)
        }
        .frame(width: faceSize * eyeWidthRatio,
               height: faceSize * eyeHeightRatio)
    }

    /// Linear fade from 40pt face size (full glimmer) down to 24pt (none).
    /// Below the floor the eyes already read clearly; the glimmer would
    /// just be a sub-pixel artifact.
    private var glimmerOpacity: Double {
        let upper: CGFloat = 40
        let lower: CGFloat = 24
        if faceSize >= upper { return 1.0 }
        if faceSize <= lower { return 0.0 }
        return Double((faceSize - lower) / (upper - lower))
    }
}

#Preview {
    VStack(spacing: 32) {
        NodMascot(size: 120) // App-icon-sized preview
        NodMascot(size: 88)  // Onboarding hero
        NodMascot(size: 48)  // Still has glimmer
        NodMascot(size: 32)  // Nav bar — glimmer faded
        NodMascot(size: 24)  // Below threshold
    }
    .padding()
    .preferredColorScheme(.dark)
}
