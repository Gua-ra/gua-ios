//
// Copyright 2023, 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI

/// The app's logo with an idle "shine" animation: a bright specular band sweeps diagonally
/// across the glossy icon every few seconds and it gently breathes.
///
/// The motion is driven by `TimelineView(.animation)` (not onAppear/PhaseAnimator) so it
/// animates reliably regardless of when/where the view appears. It is disabled under
/// Reduce Motion. The sweep is clipped to the rounded-square so it never bleeds outside.
struct AuthenticationStartLogo: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Set to `true` when using on top of `Asset.Images.launchBackground`
    let isOnGradient: Bool

    /// Extra padding needed to avoid cropping the shadows.
    private let extra: CGFloat = 32
    /// The shape that the logo is composed on top of.
    private let outerShape = RoundedRectangle(cornerRadius: 44)
    private let outerShapeShadowColor = Color(red: 0.11, green: 0.11, blue: 0.13)
    private var isLight: Bool { colorScheme == .light }
    /// The idle shine + breathing animation, disabled when the user prefers reduced motion.
    private var animated: Bool { !reduceMotion }

    var body: some View {
        Image(asset: Asset.Images.appLogo)
            .resizable()
            .scaledToFit()
            .scaleEffect(0.8)
            // The specular gloss sweep, clipped to the icon silhouette so it stays inside.
            .overlay { if animated { LogoShine(shape: outerShape) } }
            .clipShape(outerShape)
            .overlay(alignment: .center) {
                outerShape
                    .inset(by: 0.25)
                    .stroke(.white.opacity(isLight ? 1 : isOnGradient ? 0.9 : 0.25), lineWidth: 0.5)
                    .blendMode(isLight ? .normal : .overlay)
            }
            .padding(extra)
            .background {
                ZStack {
                    if !isLight, isOnGradient {
                        outerShape
                            .inset(by: 1)
                            .padding(extra)
                            .shadow(color: .black.opacity(0.5),
                                    radius: 32.91666,
                                    y: 1.05333)
                    } else {
                        outerShape
                            .inset(by: 1)
                            .padding(extra)
                            .shadow(color: outerShapeShadowColor.opacity(isLight ? 0.23 : 0.08),
                                    radius: 16,
                                    y: 8)

                        outerShape
                            .inset(by: 1)
                            .padding(extra)
                            .shadow(color: outerShapeShadowColor.opacity(0.5),
                                    radius: 16,
                                    y: 8)
                            .blendMode(.overlay)
                    }
                }
                .mask {
                    outerShape
                        .inset(by: -extra / 2)
                        .stroke(lineWidth: extra)
                        .padding(extra)
                }
            }
            .padding(-extra)
            .modifier(LogoBreathe(animated: animated))
            .accessibilityHidden(true)
    }
}

/// A bright, wide diagonal gloss band that sweeps across the icon on a loop, like light
/// catching a glossy badge. Driven off the timeline clock so it always animates.
private struct LogoShine<S: Shape>: View {
    let shape: S

    /// Seconds for one loop (sweep + a rest while parked off-screen).
    private let period = 2.8
    /// Fraction of the loop spent visibly sweeping (the rest is parked off the trailing edge).
    private let sweepFraction = 0.42

    var body: some View {
        SwiftUI.TimelineView(.animation) { context in
            GeometryReader { proxy in
                let w = proxy.size.width
                let h = proxy.size.height
                let band = w * 0.55
                let t = context.date.timeIntervalSinceReferenceDate
                let loop = (t.truncatingRemainder(dividingBy: period)) / period
                // 0 → 1 across the sweep window, then held at 1 (off the trailing edge).
                let p = min(loop / sweepFraction, 1)
                // Band centre travels from just off the leading edge to just off the trailing edge.
                let x = -band + p * (w + 2 * band)

                Rectangle()
                    .fill(LinearGradient(stops: [.init(color: .white.opacity(0), location: 0.0),
                                                 .init(color: .white.opacity(0.35), location: 0.4),
                                                 .init(color: .white.opacity(0.95), location: 0.5),
                                                 .init(color: .white.opacity(0.35), location: 0.6),
                                                 .init(color: .white.opacity(0), location: 1.0)],
                                         startPoint: .leading,
                                         endPoint: .trailing))
                    .frame(width: band, height: h * 1.8)
                    .position(x: x, y: h / 2)
                    .rotationEffect(.degrees(20))
                    .blur(radius: 1.5)
                    // Additive blend reads as a real specular highlight on the dark glossy icon.
                    .blendMode(.plusLighter)
            }
        }
        .allowsHitTesting(false)
        .clipShape(shape)
    }
}

/// A gentle breathing scale that subtly brings the logo to life. Also timeline-driven.
private struct LogoBreathe: ViewModifier {
    let animated: Bool

    func body(content: Content) -> some View {
        if animated {
            SwiftUI.TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let pulse = (1 - cos(t / 2.6 * 2 * .pi)) / 2 // smooth 0 → 1 → 0
                content.scaleEffect(1.0 + 0.04 * pulse)
            }
        } else {
            content
        }
    }
}
