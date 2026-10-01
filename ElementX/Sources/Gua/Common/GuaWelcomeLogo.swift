//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import CoreMotion
import SwiftUI

struct GuaWelcomeLogo: View {
    /// `false` under Reduce Motion and in snapshot tests.
    let animated: Bool
    var size: CGFloat = 84

    private let corner: CGFloat = 21
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
    }

    @State private var tilt = DeviceTiltMotion()
    @State private var entered = false
    @State private var entranceScheduled = false
    @State private var renderedLeadIn: TimeInterval = 0
    @State private var lastTick: TimeInterval?

    private var isLive: Bool {
        animated && !ProcessInfo.isRunningTests
    }

    private var entranceTravel: CGFloat {
        size * 2.6
    }

    var body: some View {
        Group {
            if isLive {
                SwiftUI.TimelineView(.animation) { context in
                    treated(t: context.date.timeIntervalSinceReferenceDate)
                        .onChange(of: context.date) { startEntranceIfNeeded(now: context.date) }
                }
            } else {
                treated(t: 0)
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(entered ? 1 : 0.82)
        .rotation3DEffect(.degrees(entered ? 0 : 68), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
        .offset(x: entered ? 0 : entranceTravel)
        .opacity(entered ? 1 : 0)
        .accessibilityHidden(true)
        .onAppear {
            if isLive {
                tilt.start()
            } else {
                entered = true
            }
        }
        .onDisappear { tilt.stop() }
    }

    /// Starts the entrance after about 0.35s of rendered frames: at launch `onAppear` fires behind the launch screen,
    /// so a spring started there finishes unseen.
    private func startEntranceIfNeeded(now: Date) {
        guard !entranceScheduled else { return }
        let t = now.timeIntervalSinceReferenceDate
        defer { lastTick = t }
        guard let lastTick else { return }
        renderedLeadIn += min(t - lastTick, 1 / 20)
        guard renderedLeadIn >= 0.35 else { return }
        entranceScheduled = true
        withAnimation(.spring(response: 0.52, dampingFraction: 0.66)) {
            entered = true
        }
    }

    private func treated(t: TimeInterval) -> some View {
        logo
            .overlay { glyphRelief() }
            .overlay { sheen(t: t) }
            .overlay { glassHighlight() }
            .overlay { innerRimLine() }
            .clipShape(shape)
            .overlay { outerRimLine() }
            .offset(x: tilt.roll * size * 0.025, y: tilt.pitch * size * 0.025)
            .background { aura(t: t) }
            .rotation3DEffect(.degrees(tilt.pitch * 5), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees(tilt.roll * 5), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
    }

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

    private var rimLightAngle: Angle {
        Angle(radians: atan2(tilt.roll, -tilt.pitch) - .pi / 2)
    }

    // MARK: - Glyph liquid-glass bevel

    private var tiltMagnitude: Double {
        min(1, (tilt.roll * tilt.roll + tilt.pitch * tilt.pitch).squareRoot())
    }

    /// Fixed overhead light: a bevel that tracks tilt renders the glyph layers as offset duplicates.
    private var bevelLightVector: CGSize {
        CGSize(width: 0, height: -1)
    }

    private func glyphRelief() -> some View {
        let mag = tiltMagnitude
        let depth = size * 0.014

        return ZStack {
            glyphBevel(asset: Asset.Images.appLogoBubble, depth: depth * 0.85, mag: mag)
            glyphBevel(asset: Asset.Images.appLogoWolf, depth: depth * 1.15, mag: mag)
        }
        .allowsHitTesting(false)
    }

    private func glyphBevel(asset: ImageAsset, depth: CGFloat, mag: Double) -> some View {
        ZStack {
            glyphCrescent(asset: asset,
                          color: .white,
                          offset: CGSize(width: bevelLightVector.width * depth, height: bevelLightVector.height * depth))
                .opacity(0.55 + 0.30 * mag)
                .blendMode(.screen)
            glyphCrescent(asset: asset,
                          color: .black,
                          offset: CGSize(width: -bevelLightVector.width * depth * 0.8, height: -bevelLightVector.height * depth * 0.8))
                .opacity(0.22 + 0.14 * mag)
        }
    }

    private func glyphCrescent(asset: ImageAsset, color: Color, offset: CGSize) -> some View {
        ZStack {
            glyphTemplate(asset, color: color)
                .offset(offset)
            glyphTemplate(asset, color: .black)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .blur(radius: size * 0.006)
    }

    private func glyphTemplate(_ asset: ImageAsset, color: Color) -> some View {
        Image(asset: asset)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(color)
    }

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

    private func sheen(t: TimeInterval) -> some View {
        let cycle = 11.0
        let sweepDuration = 1.0
        let phase = t.truncatingRemainder(dividingBy: cycle)
        let progress = min(phase / sweepDuration, 1)
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

    private func aura(t: TimeInterval) -> some View {
        let hue = 0.40 + 0.05 * sin(t * (2 * .pi / 4.0))
        let drift = size * 0.06

        return shape
            .fill(Color(hue: hue, saturation: 0.8, brightness: 0.95))
            .opacity(0.30)
            .frame(width: size * 1.28, height: size * 1.28)
            .offset(x: cos(t * (2 * .pi / 5.0)) * drift,
                    y: sin(t * (2 * .pi / 6.0)) * drift)
            .blur(radius: size * 0.28)
            .allowsHitTesting(false)
    }
}

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
