//
// Copyright 2023, 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI

/// The app's logo styled to fit on various launch pages.
///
/// On top of the static icon it layers a "liquid sheen": a bright specular band that
/// travels diagonally across the glossy surface, a highlight that shimmers around the
/// rounded-square border, and a soft breathing glow. Everything loops smoothly, stays
/// clipped to the icon silhouette, and is disabled when the user prefers reduced motion.
///
/// Snapshot-safety: the animated overlays are gated behind `isLive`, which only flips on
/// after the view appears. The first, synchronously-rendered frame therefore shows the
/// plain static logo, so snapshot tests remain stable.
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
    /// The idle liquid-sheen animation, disabled when the user prefers reduced motion.
    private var animated: Bool { !reduceMotion }

    /// Flips to `true` once the view has appeared. Keeping the animated overlays off for
    /// the very first frame guarantees a synchronous snapshot matches the static logo.
    @State private var isLive = false

    /// `true` only when the sheen should actually be running on screen.
    private var isAnimating: Bool { animated && isLive }

    var body: some View {
        Image(asset: Asset.Images.appLogo)
            .resizable()
            .scaledToFit()
            .scaleEffect(0.8)
            // The specular gloss sweep, clipped to the icon silhouette so it never bleeds out.
            .overlay { if isAnimating { SpecularSweep(shape: outerShape) } }
            .clipShape(outerShape)
            .overlay(alignment: .center) {
                outerShape
                    .inset(by: 0.25)
                    .stroke(.white.opacity(isLight ? 1 : isOnGradient ? 0.9 : 0.25), lineWidth: 0.5)
                    .blendMode(isLight ? .normal : .overlay)
            }
            // A highlight that travels around the border, layered over the static stroke.
            .overlay { if isAnimating { ShimmerStroke(shape: outerShape) } }
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
            // A soft halo that pulses behind the icon, reinforcing the "alive" feel.
            .background { if isAnimating { PulsingGlow(shape: outerShape, inset: extra) } }
            .padding(-extra)
            .breathing(isAnimating)
            .onAppear { isLive = true }
            .onDisappear { isLive = false }
            .accessibilityHidden(true)
    }
}

/// A bright, wide diagonal gloss band that sweeps across the logo on a smooth loop,
/// giving it the look of light catching a glossy badge.
///
/// **Phase 0 (`rest`) parks the band fully off-screen**, so even if the animator's first
/// frame is captured synchronously it shows nothing — keeping snapshots clean. The band is
/// only ever mounted once `isAnimating` is true, which is a second guarantee of the same.
private struct SpecularSweep<S: Shape>: View {
    let shape: S

    /// Each loop: a brisk, eased pass across the icon, then a hold before repeating.
    private enum Phase: CaseIterable {
        /// Band parked just before the leading edge — the rest / snapshot frame.
        case rest
        /// Band has travelled all the way past the trailing edge.
        case swept
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            // A wide band so the gloss reads clearly rather than as a thin glint.
            let bandWidth = size.width * 0.7
            // Distance the band centre must travel to clear the (rotated) icon on both sides.
            let travel = size.width + bandWidth

            band(bandWidth: bandWidth, height: size.height)
                .phaseAnimator(Phase.allCases) { content, phase in
                    content
                        .offset(x: phase == .swept ? travel / 2 : -travel / 2)
                } animation: { phase in
                    switch phase {
                    // The visible pass: smooth and a touch brisk so it clearly "catches the light".
                    case .swept: .easeInOut(duration: 1.15)
                    // Instant reset back to rest, then hold so the loop lands ~every 2.7s.
                    case .rest: .linear(duration: 0).delay(1.55)
                    }
                }
        }
        .allowsHitTesting(false)
        // Belt-and-braces clip to the rounded-square so the gloss stays inside the icon.
        .clipShape(shape)
    }

    /// The gloss band itself: a soft, bright diagonal highlight with a hot core.
    private func band(bandWidth: CGFloat, height: CGFloat) -> some View {
        let gradient = LinearGradient(stops: [.init(color: .white.opacity(0), location: 0.0),
                                              .init(color: .white.opacity(0.25), location: 0.35),
                                              .init(color: .white.opacity(0.95), location: 0.5),
                                              .init(color: .white.opacity(0.25), location: 0.65),
                                              .init(color: .white.opacity(0), location: 1.0)],
                                      startPoint: .leading,
                                      endPoint: .trailing)
        return Rectangle()
            .fill(gradient)
            .frame(width: bandWidth)
            // Over-tall so the rotated band fully covers the icon corner to corner.
            .frame(height: height * 1.8)
            .blur(radius: 2)
            .rotationEffect(.degrees(22))
            // Additive blend reads as a real specular highlight on the dark glossy gradient.
            .blendMode(.plusLighter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A bright point of light that continuously travels around the rounded-square border,
/// layered over the existing static stroke to make the edge shimmer.
///
/// Driven by `TimelineView(.animation)` rotating an `AngularGradient`. It is purely a
/// stroke overlay that is only mounted once `isAnimating` is true, so the resting first
/// frame renders nothing at all, keeping snapshots stable.
private struct ShimmerStroke<S: InsettableShape>: View {
    let shape: S

    var body: some View {
        SwiftUI.TimelineView(.animation) { context in
            let cycle = 4.2 // seconds for the highlight to travel once around the border
            let t = context.date.timeIntervalSinceReferenceDate
            let angle = (t.truncatingRemainder(dividingBy: cycle)) / cycle * 360

            shape
                .inset(by: 0.25)
                .stroke(AngularGradient(stops: [.init(color: .white.opacity(0), location: 0.00),
                                                .init(color: .white.opacity(0), location: 0.34),
                                                .init(color: .white.opacity(0.9), location: 0.5),
                                                .init(color: .white.opacity(0), location: 0.66),
                                                .init(color: .white.opacity(0), location: 1.00)],
                                        center: .center,
                                        angle: .degrees(angle)),
                        lineWidth: 1)
                .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
        // Keep the shimmer strictly on the silhouette.
        .clipShape(shape)
    }
}

/// A soft white halo that gently pulses behind the icon. Sitting in the background (behind
/// the icon image) means it reads as glow spilling out from the edges rather than haze over
/// the artwork. Only mounted while `isAnimating`, so it is absent from the resting frame.
private struct PulsingGlow<S: InsettableShape>: View {
    let shape: S
    let inset: CGFloat

    var body: some View {
        SwiftUI.TimelineView(.animation) { context in
            let cycle = 2.7
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = (t.truncatingRemainder(dividingBy: cycle)) / cycle
            // 0 -> 1 -> 0 smooth pulse.
            let pulse = (1 - cos(phase * 2 * .pi)) / 2
            let opacity = 0.1 + 0.22 * pulse

            shape
                .inset(by: 1)
                .fill(.white.opacity(opacity))
                .blur(radius: 26)
                .padding(inset)
                .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
    }
}

private extension View {
    /// A gentle breathing scale that subtly brings the logo to life while idle.
    /// Phase 0 is the resting scale (1.0) so the first frame matches the static logo.
    @ViewBuilder
    func breathing(_ enabled: Bool) -> some View {
        if enabled {
            phaseAnimator([false, true]) { content, breathing in
                content.scaleEffect(breathing ? 1.04 : 1.0)
            } animation: { _ in
                .easeInOut(duration: 2.7)
            }
        } else {
            self
        }
    }
}
