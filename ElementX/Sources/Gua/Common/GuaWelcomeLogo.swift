//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI

/// The welcome-screen app logo rendered as a premium "liquid glass" object.
///
/// Replaces the earlier broad colour halo (which read as "too much" and barely moved) with motion
/// that is obvious yet contained to the icon:
///  - a bright **specular sheen** that sweeps diagonally across the glass every ~2.4s (the clearly
///    visible, fast motion),
///  - a gentle **3D parallax rock** on two axes so the tile feels physical,
///  - a soft **pulse** (scale + glow), and
///  - only a small, contained Gua-green glow instead of a big saturated aura.
///
/// All motion is driven by `SwiftUI.TimelineView(.animation)` (display-link backed; the `SwiftUI.`
/// qualifier avoids ElementX's own `TimelineView`), so it always runs while on screen — no
/// `.onAppear` + `withAnimation(.repeatForever)`. Static under Reduce Motion and in snapshot tests.
struct GuaWelcomeLogo: View {
    /// When `false` (Reduce Motion) the logo is drawn as a still glass tile.
    let animated: Bool
    var size: CGFloat = 84

    private let corner: CGFloat = 21
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: corner, style: .continuous) }

    var body: some View {
        Group {
            if animated, !ProcessInfo.isRunningTests {
                SwiftUI.TimelineView(.animation) { context in
                    treated(t: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                treated(t: 0)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func treated(t: TimeInterval) -> some View {
        let pulse = sin(t * (2 * .pi / 3.0))           // -1...1 over 3s
        let scale = 1 + 0.022 * pulse                  // gentle breathing
        let tiltX = cos(t * (2 * .pi / 4.0)) * 7       // 3D rock, two out-of-phase axes
        let tiltY = sin(t * (2 * .pi / 5.0)) * 7
        let sweep = t.truncatingRemainder(dividingBy: 2.4) / 2.4 // glass sheen, one pass / 2.4s

        return logo
            .overlay { sheen(sweep) }
            .clipShape(shape)
            .overlay { shape.stroke(.white.opacity(0.16), lineWidth: 0.5) } // crisp glass edge
            .background { glow(pulse) }
            .scaleEffect(scale)
            .rotation3DEffect(.degrees(tiltX), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees(tiltY), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
    }

    private var logo: some View {
        Image(asset: Asset.Images.appLogo)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }

    /// A soft white highlight band travelling diagonally across the glass (clipped to the logo by
    /// the caller's `.clipShape`). `.screen` blend makes it read as light catching the surface.
    private func sheen(_ progress: Double) -> some View {
        LinearGradient(colors: [.clear, .white.opacity(0.55), .clear],
                       startPoint: .top, endPoint: .bottom)
            .frame(width: size * 0.42, height: size * 2)
            .rotationEffect(.degrees(35))
            .offset(x: -size * 0.95 + size * 1.9 * progress)
            .blendMode(.screen)
            .allowsHitTesting(false)
    }

    /// A small, contained Gua-green glow that breathes — a brand hint, not a saturated halo.
    private func glow(_ pulse: Double) -> some View {
        shape
            .fill(Color(red: 0.20, green: 0.95, blue: 0.55))
            .opacity(0.16 + 0.10 * (pulse * 0.5 + 0.5))
            .scaleEffect(1.08)
            .blur(radius: size * 0.20)
    }
}
