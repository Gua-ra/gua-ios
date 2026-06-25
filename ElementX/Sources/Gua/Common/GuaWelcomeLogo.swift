//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import CoreMotion
import SwiftUI

/// The welcome-screen app logo: the Gua app-icon artwork presented as a raised glass tile.
///
/// Comes alive in three ways:
///  - **Entrance** (one-shot, on appear): the logo flies in from the side and spins into place with a
///    spring settle. Pure SwiftUI `@State` — plays on the simulator too. Skipped under Reduce Motion.
///  - **Device-motion angle-of-view** (`CoreMotion`): the logo tilts ±5° in 3D as the phone moves,
///    and a specular highlight sweeps around the two concentric glass-edge lines tracking the tilt
///    direction. Still phone → clean icon, no motion. No gyroscope on simulator (tilt stays at rest
///    there; the entrance still plays).
///  - **Light** (`SwiftUI.TimelineView(.animation)`, display-link backed; `SwiftUI.` qualifier avoids
///    ElementX's own `TimelineView`): an occasional diagonal sheen sweep across the glass (~1s every
///    ~11s) and a steady Gua-green aura behind the tile.
///
/// Static under Reduce Motion (`animated == false`) and in snapshot tests.
struct GuaWelcomeLogo: View {
    /// When `false` (Reduce Motion) the logo is drawn as a still glass tile with no entrance.
    let animated: Bool
    var size: CGFloat = 84

    private let corner: CGFloat = 21
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
    }

    @State private var tilt = DeviceTiltMotion()
    /// Drives the one-shot fly-in/spin entrance: starts off-screen + rotated, springs to rest.
    @State private var entered = false

    private var isLive: Bool {
        animated && !ProcessInfo.isRunningTests
    }

    /// Off-screen starting offset for the entrance fly-in (the logo arrives from the trailing side).
    private var entranceTravel: CGFloat {
        size * 2.6
    }

    var body: some View {
        Group {
            if isLive {
                SwiftUI.TimelineView(.animation) { context in
                    treated(t: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                treated(t: 0)
            }
        }
        .frame(width: size, height: size)
        // One-shot entrance, applied on the OUTER container (independent of the per-frame
        // TimelineView) so it plays exactly once. Unlike the device-motion parallax it needs no
        // gyroscope, so it is fully visible on the simulator too.
        .scaleEffect(entered ? 1 : 0.82)
        .rotation3DEffect(.degrees(entered ? 0 : 68), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
        .offset(x: entered ? 0 : entranceTravel)
        .opacity(entered ? 1 : 0)
        .accessibilityHidden(true)
        .onAppear {
            if isLive { tilt.start() }
            guard !entered else { return }
            if animated {
                withAnimation(.spring(response: 0.52, dampingFraction: 0.66).delay(0.1)) {
                    entered = true
                }
            } else {
                entered = true // Reduce Motion / tests: appear in place, no fly-in.
            }
        }
        .onDisappear { tilt.stop() }
    }

    private func treated(t: TimeInterval) -> some View {
        logo
            .overlay { sheen(t: t) }
            .overlay { glassHighlight() }
            .overlay { innerRimLine() } // inner edge line, clipped to icon boundary
            .clipShape(shape)
            .overlay { outerRimLine() } // outer edge line, unclipped — creates the double-line look
            .background { aura(t: t) }
            // Whole logo tilts ±5° in 3D — shifting the angle-of-view of the raised glass edges.
            .rotation3DEffect(.degrees(tilt.pitch * 5), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees(tilt.roll * 5), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
    }

    /// A specular hotspot that slides across the glass as the device tilts — light catching a real
    /// glass surface. Driven purely by `CoreMotion`, so it's still when the phone is still (and
    /// sits centred on the simulator). Clipped to the logo by the caller's `.clipShape`.
    private func glassHighlight() -> some View {
        // Only catches the light while the phone is actually tilting; when still it fades to nothing
        // so it never pools as a bright spot in the centre of the icon.
        let mag = min(1, (tilt.roll * tilt.roll + tilt.pitch * tilt.pitch).squareRoot() * 1.7)
        return RadialGradient(colors: [.white.opacity(0.4), .white.opacity(0.08), .clear],
                              center: .center, startRadius: 0, endRadius: size * 0.55)
            .frame(width: size, height: size)
            .offset(x: tilt.roll * size * 0.32, y: -tilt.pitch * size * 0.32)
            .opacity(mag)
            .blendMode(.screen)
            .allowsHitTesting(false)
    }

    private var logo: some View {
        Image(asset: Asset.Images.appLogo)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }

    /// The tilt-driven light-source angle for the rim specular.
    /// At rest (roll=0, pitch=0) the highlight sits at 12 o'clock — natural overhead light.
    private var rimLightAngle: Angle {
        Angle(radians: atan2(tilt.roll, -tilt.pitch) - .pi / 2)
    }

    /// Inner glass-edge line — sits ~2.5 pt inside the clip boundary, with a specular highlight
    /// that tracks the tilt direction. Placed before `.clipShape` so it's bounded by the icon.
    private func innerRimLine() -> some View {
        RoundedRectangle(cornerRadius: corner - 2.5, style: .continuous)
            .stroke(AngularGradient(stops: [
                        .init(color: .white.opacity(0.85), location: 0.00),
                        .init(color: .white.opacity(0.18), location: 0.28),
                        .init(color: .clear, location: 0.50),
                        .init(color: .white.opacity(0.18), location: 0.72),
                        .init(color: .white.opacity(0.85), location: 1.00)
                    ],
                    center: .center,
                    startAngle: rimLightAngle,
                    endAngle: rimLightAngle + .degrees(360)),
                    lineWidth: 1.0)
            .allowsHitTesting(false)
    }

    /// Outer glass-edge line — sits at the clip boundary (placed after `.clipShape`, so it's not
    /// clipped). Together with `innerRimLine` this creates the double-line raised-glass-edge look.
    private func outerRimLine() -> some View {
        shape
            .stroke(AngularGradient(stops: [
                        .init(color: .white.opacity(0.55), location: 0.00),
                        .init(color: .white.opacity(0.07), location: 0.28),
                        .init(color: .clear, location: 0.50),
                        .init(color: .white.opacity(0.07), location: 0.72),
                        .init(color: .white.opacity(0.55), location: 1.00)
                    ],
                    center: .center,
                    startAngle: rimLightAngle,
                    endAngle: rimLightAngle + .degrees(360)),
                    lineWidth: 1.0)
            .allowsHitTesting(false)
    }

    /// A soft white highlight band that sweeps diagonally across the glass (clipped to the logo by
    /// the caller's `.clipShape`). One ~1s pass per ~11s cycle, with a clear idle pause between, so the
    /// sheen reads as an occasional catch of light rather than a constant loop. `.screen` blend makes
    /// it read as light catching the surface.
    private func sheen(t: TimeInterval) -> some View {
        let cycle = 11.0 // total period (glare sweeps less often)
        let sweepDuration = 1.0 // visible travel, then idle for the remainder
        let phase = t.truncatingRemainder(dividingBy: cycle)
        let progress = min(phase / sweepDuration, 1) // 0...1 during the sweep, parked at 1 while idle
        let visible = phase < sweepDuration

        return LinearGradient(colors: [.clear, .white.opacity(0.55), .clear],
                              startPoint: .top, endPoint: .bottom)
            .frame(width: size * 0.42, height: size * 2)
            .rotationEffect(.degrees(35))
            .offset(x: -size * 0.95 + size * 1.9 * progress)
            .opacity(visible ? 1 : 0)
            .blendMode(.screen)
            .allowsHitTesting(false)
    }

    /// A lively Gua-green aura that sits behind the icon and spills ~28% past its edges as a soft
    /// halo. The hue drifts gently around Gua green and the glow slowly shifts position — visible
    /// and alive, but steady (no breathing/pulsing) and still tasteful.
    private func aura(t: TimeInterval) -> some View {
        let hue = 0.40 + 0.05 * sin(t * (2 * .pi / 4.0)) // gentle drift around Gua green
        let drift = size * 0.06

        return shape
            .fill(Color(hue: hue, saturation: 0.8, brightness: 0.95))
            .opacity(0.30) // steady glow — no breathing
            .frame(width: size * 1.28, height: size * 1.28) // spill ~28% beyond the icon
            .offset(x: cos(t * (2 * .pi / 5.0)) * drift,
                    y: sin(t * (2 * .pi / 6.0)) * drift)
            .blur(radius: size * 0.28)
            .allowsHitTesting(false)
    }
}

/// Publishes the device's `roll` and `pitch` (each roughly -1...1) from `CoreMotion`, smoothed so the
/// parallax tilt eases rather than jitters. Device-motion updates require no `Info.plist` permission.
/// On hardware without a gyroscope (e.g. the simulator) `isDeviceMotionAvailable` is `false`, so the
/// values stay at zero and the logo simply doesn't tilt.
@Observable
final class DeviceTiltMotion {
    private(set) var roll: Double = 0
    private(set) var pitch: Double = 0

    @ObservationIgnored private let manager = CMMotionManager()

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }

        manager.deviceMotionUpdateInterval = 1 / 30
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let attitude = motion?.attitude else { return }
            // Clamp to a small range and ease towards the target so motion is gentle and smooth.
            let targetRoll = max(-1, min(1, attitude.roll / (.pi / 6)))
            let targetPitch = max(-1, min(1, attitude.pitch / (.pi / 6)))
            roll += (targetRoll - roll) * 0.15
            pitch += (targetPitch - pitch) * 0.15
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        roll = 0
        pitch = 0
    }
}
