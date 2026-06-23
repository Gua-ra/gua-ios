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
/// Motion model — deliberately minimal; the logo is otherwise completely still:
///  - **Entrance**: on first appearance it rapidly slides in from the side and settles with a
///    gentle spring (fade + slight scale). A one-shot, elegant intro.
///  - **Device motion only** (`CoreMotion`): after that the logo moves *only* when the device
///    moves — a home-screen-icon-style parallax shift plus a subtle 3D glass tilt, with the raised
///    wolf/bubble layers and a glass highlight tracking the tilt. When the phone is still it is
///    perfectly still (also under Reduce Motion, in snapshot tests, and on the simulator).
///
/// There is no autonomous/looping animation — no breathing, no sheen sweep, no drifting aura.
struct GuaWelcomeLogo: View {
    /// When `false` (Reduce Motion) the logo is drawn as a still glass tile with no entrance.
    let animated: Bool
    var size: CGFloat = 84

    private let corner: CGFloat = 21
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: corner, style: .continuous) }

    @State private var tilt = DeviceTiltMotion()
    @State private var appeared = false

    private var isLive: Bool { animated && !ProcessInfo.isRunningTests }

    /// How far off to the side the logo starts before sliding in.
    private var entranceDistance: CGFloat { size * 2.2 }

    // Entrance transform — neutral (no offset, fully shown) unless we're live and haven't appeared yet,
    // so Reduce Motion / snapshot tests render the final still logo with no intro.
    private var entering: Bool { isLive && !appeared }
    private var entranceX: CGFloat { entering ? -entranceDistance : 0 }
    private var entranceScale: CGFloat { entering ? 0.92 : 1 }
    private var entranceOpacity: Double { entering ? 0 : 1 }

    var body: some View {
        treated
            .frame(width: size, height: size)
            // Device-motion parallax (home-screen-icon feel): the whole logo shifts a little with the
            // device tilt. Exactly zero when the phone is still / on the simulator.
            .offset(x: tilt.roll * size * 0.06, y: tilt.pitch * size * 0.06)
            // One-shot entrance: slide in from the leading side + fade + settle.
            .offset(x: entranceX)
            .scaleEffect(entranceScale)
            .opacity(entranceOpacity)
            .accessibilityHidden(true)
            .onAppear {
                if isLive { tilt.start() }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) {
                    appeared = true
                }
            }
            .onDisappear { tilt.stop() }
    }

    private var treated: some View {
        logo
            .overlay { bubbleLayer() }
            .overlay { wolfLayer() }
            .overlay { glassHighlight() }
            .clipShape(shape)
            .overlay { shape.stroke(.white.opacity(0.16), lineWidth: 0.5) } // crisp glass edge
            .background { aura }
            // Subtle 3D glass tilt, device-driven — no movement when the phone is still.
            .rotation3DEffect(.degrees(tilt.pitch * 6), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees(tilt.roll * 6), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
    }

    /// A specular hotspot that slides across the glass as the device tilts. Driven purely by
    /// `CoreMotion`, so it fades to nothing when the phone is still (never a bright centre spot).
    private func glassHighlight() -> some View {
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

    /// The chat bubble and the wolf are split into their OWN layers (`app-logo-bubble`,
    /// `app-logo-wolf`) stacked above the tile. They stay visible even when still (raised-glass
    /// relief); only the parallax offset + drop shadow scale with the device tilt.

    /// Mid layer: the chat-bubble outline, lifted a little off the tile.
    private func bubbleLayer() -> some View {
        Image("app-logo-bubble")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.22), radius: size * 0.025,
                    x: -tilt.roll * size * 0.02, y: -tilt.pitch * size * 0.02)
            .offset(x: tilt.roll * size * 0.03, y: tilt.pitch * size * 0.03)
            .opacity(0.95) // always-on raised relief — stays visible when the phone is still
            .allowsHitTesting(false)
    }

    /// Top layer: the wolf, raised highest — biggest parallax shift + deepest shadow.
    private func wolfLayer() -> some View {
        Image("app-logo-wolf")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.3), radius: size * 0.04,
                    x: -tilt.roll * size * 0.04, y: -tilt.pitch * size * 0.04)
            .offset(x: tilt.roll * size * 0.06, y: tilt.pitch * size * 0.06)
            .opacity(1) // always-on raised relief — stays visible when the phone is still
            .allowsHitTesting(false)
    }

    /// A steady Gua teal-green aura behind the icon, spilling ~28% past its edges as a soft halo.
    /// Completely static — it glows but never moves or pulses.
    private var aura: some View {
        shape
            .fill(Color(hue: 0.44, saturation: 0.85, brightness: 0.85)) // steady Gua teal-green
            .opacity(0.30)
            .frame(width: size * 1.28, height: size * 1.28) // spill ~28% beyond the icon
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
