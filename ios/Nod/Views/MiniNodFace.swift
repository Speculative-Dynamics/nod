// MiniNodFace.swift
// The navigation bar's leading brand element (replaces the "Nod"
// title). Also the intended tap-target for opening the sidebar in the
// future — stub action for now.
//
// Pure semantic wrapper around NodMascotBlinker at the nav-bar size.
// The name sticks because "MiniNodFace" reads clearly at call sites;
// the actual blink/geometry/color all live in NodMascot.swift.

import SwiftUI

struct MiniNodFace: View {
    var size: CGFloat = 32

    var body: some View {
        NodMascotBlinker(size: size)
    }
}

#Preview {
    MiniNodFace()
        .padding()
        .preferredColorScheme(.dark)
}
