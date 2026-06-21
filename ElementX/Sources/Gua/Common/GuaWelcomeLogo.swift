//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import CoreMotion
import SwiftUI

/// The welcome-screen app logo rendered as a premium "liquid glass" object.
///
/// There is **no breathing/pulsing** — the logo stays a fixed size. It feels alive through *light*
/// and *depth* instead:
///  - **Time-based** (`SwiftUI.TimelineView(.animation)`, display-link backed; the `SwiftUI.`
///    qualifier avoids ElementX's own `TimelineView`): an occasional specular **sheen** that sweeps
///    across the glass (a ~1s pass roughly every 11s, not a constant loop) and a steady coloured
///    **aura** that spills past the icon edges and gently drifts.
///  - **Device-motion-based** (`CoreMotion`): a subtle 3D **parallax tilt** (a few degrees) plus a
///    **glass highlight** — a specular hotspot that slides across the surface as the user tilts the
///    phone, like light catching real glass. When the phone is still there is no motion; on the
///    simulator (no gyro) the logo simply sits with a centred highlight.
///
/// Static under Reduce Motion (`animated == false`) and in snapshot tests.
struct GuaWelcomeLogo: View {
    /// When `false` (Reduce Motion) the logo is drawn as a still glass tile.
    let animated: Bool
    var size: CGFloat = 84

    private let corner: CGFloat = 21
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: corner, style: .continuous) }

    @State private var tilt = DeviceTiltMotion()

    private var isLive: Bool { animated && !ProcessInfo.isRunningTests }

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
        .accessibilityHidden(true)
        .onAppear { if isLive { tilt.start() } }
        .onDisappear { tilt.stop() }
    }

    private func treated(t: TimeInterval) -> some View {
        // No breathing/pulsing — the logo comes alive only through light (the sheen sweep + the
        // tilt-tracking glass highlight) and the device-motion parallax tilt.
        logo
            .overlay { foreground() }
            .overlay { sheen(t: t) }
            .overlay { glassHighlight() }
            .clipShape(shape)
            .overlay { shape.stroke(.white.opacity(0.16), lineWidth: 0.5) } // crisp glass edge
            .background { aura(t: t) }
            // Subtle device-motion parallax: ±5° max, no movement when the phone is still.
            .rotation3DEffect(.degrees(tilt.pitch * 5), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees(tilt.roll * 5), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
    }

    /// A specular hotspot that slides across the glass as the device tilts — light catching a real
    /// glass surface. Driven purely by `CoreMotion`, so it's still when the phone is still (and
    /// sits centred on the simulator). Clipped to the logo by the caller's `.clipShape`.
    private func glassHighlight() -> some View {
        RadialGradient(colors: [.white.opacity(0.5), .white.opacity(0.12), .clear],
                       center: .center, startRadius: 0, endRadius: size * 0.55)
            .frame(width: size, height: size)
            .offset(x: tilt.roll * size * 0.3, y: -tilt.pitch * size * 0.3)
            .blendMode(.screen)
            .allowsHitTesting(false)
    }

    private var logo: some View {
        Image(asset: Asset.Images.appLogo)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }

    /// The wolf + chat-bubble lines, extracted to their own layer (`app-logo-foreground`) and shifted
    /// a little MORE than the base tile as the phone tilts, with a soft offset shadow — so they read
    /// as a raised, 3D-detached element floating above the gradient (the "liquid glass" depth). When
    /// the phone is still (or Reduce Motion) tilt is zero, so it sits flush like a normal icon.
    private func foreground() -> some View {
        Image("app-logo-foreground")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.3), radius: size * 0.03,
                    x: -tilt.roll * size * 0.035, y: -tilt.pitch * size * 0.035)
            .offset(x: tilt.roll * size * 0.05, y: tilt.pitch * size * 0.05)
            .allowsHitTesting(false)
    }

    /// A soft white highlight band that sweeps diagonally across the glass (clipped to the logo by
    /// the caller's `.clipShape`). One ~1s pass per ~11s cycle, with a clear idle pause between, so the
    /// sheen reads as an occasional catch of light rather than a constant loop. `.screen` blend makes
    /// it read as light catching the surface.
    private func sheen(t: TimeInterval) -> some View {
        let cycle = 11.0                                 // total period (glare sweeps less often)
        let sweepDuration = 1.0                          // visible travel, then idle for the remainder
        let phase = t.truncatingRemainder(dividingBy: cycle)
        let progress = min(phase / sweepDuration, 1)     // 0...1 during the sweep, parked at 1 while idle
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
        let hue = 0.40 + 0.05 * sin(t * (2 * .pi / 4.0))   // gentle drift around Gua green
        let drift = size * 0.06

        return shape
            .fill(Color(hue: hue, saturation: 0.8, brightness: 0.95))
            .opacity(0.30)                                   // steady glow — no breathing
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
