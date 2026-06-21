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
/// Motion is split between two sources:
///  - **Time-based** (`SwiftUI.TimelineView(.animation)`, display-link backed; the `SwiftUI.`
///    qualifier avoids ElementX's own `TimelineView`): an occasional specular **sheen** that sweeps
///    across the glass (a ~1s pass roughly every 11s, not a constant loop) and a lively coloured
///    **aura** that spills past the icon edges as a soft moving halo.
///  - **Device-motion-based** (`CoreMotion`): a subtle 3D **parallax tilt** (a few degrees) that only
///    responds as the user physically tilts the phone — like the home-screen depth effect. When the
///    phone is still there is no motion; on the simulator (no gyro) the logo simply stays put.
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
        let pulse = sin(t * (2 * .pi / 5.0))           // -1...1 over 5s, slow gentle breathing

        return logo
            .overlay { sheen(t: t) }
            .clipShape(shape)
            .overlay { shape.stroke(.white.opacity(0.16), lineWidth: 0.5) } // crisp glass edge
            .background { aura(t: t) }
            // Subtle device-motion parallax: ±5° max, no movement when the phone is still.
            .rotation3DEffect(.degrees(tilt.pitch * 5), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees(tilt.roll * 5), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .scaleEffect(1 + 0.018 * pulse)
            .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
    }

    private var logo: some View {
        Image(asset: Asset.Images.appLogo)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
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

    /// A lively Gua-green aura that sits behind the icon and spills ~25% past its edges as a soft
    /// moving halo. The hue drifts gently around Gua green and the glow shifts/breathes faster than
    /// the icon itself — visible and alive, but still tasteful (not a huge saturated ring).
    private func aura(t: TimeInterval) -> some View {
        let breathe = sin(t * (2 * .pi / 4.0)) * 0.5 + 0.5 // 0...1 over 4s (slow; still a touch faster than the icon)
        let hue = 0.40 + 0.05 * sin(t * (2 * .pi / 4.0))   // drift around Gua green
        let drift = size * 0.06

        return shape
            .fill(Color(hue: hue, saturation: 0.8, brightness: 0.95))
            .opacity(0.22 + 0.16 * breathe)
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
