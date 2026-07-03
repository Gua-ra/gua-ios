//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import CoreMotion
import SwiftUI

/// The welcome-screen app logo: the Gua app-icon artwork presented as a raised liquid-glass tile.
///
/// Comes alive in four ways:
///  - **Entrance** (one-shot, on appear): the logo flies in from the side and spins into place with a
///    spring settle. Pure SwiftUI `@State` — plays on the simulator too. Skipped under Reduce Motion.
///  - **Aurora** (`SwiftUI.TimelineView(.animation)`, display-link backed; the `SwiftUI.` qualifier
///    avoids ElementX's own `TimelineView`): a soft Siri-style aurora halo behind the tile — the
///    `GuaAuroraGlow` palette (Gua green leading cyan/blue/purple/pink) flowing through an
///    iOS 18 `MeshGradient`, with a radial-blob fallback on iOS 17. Also an occasional diagonal
///    sheen sweep across the glass (~1s every ~11s).
///  - **Liquid glass**: the wolf-in-speech-bubble glyph gets a specular bevel — thin light/shadow
///    crescents hugging the glyph edges (derived from the `appLogoWolf` / `appLogoBubble` layer
///    assets), plus the double rim line around the tile. On iOS 26 the tile surface additionally
///    picks up the system's clear `glassEffect`.
///  - **Device-motion angle-of-view** (`CoreMotion`): the tile tilts ±5° in 3D as the phone moves,
///    the specular light source swings with the tilt (rim lines + glyph bevel track it), and the
///    tile content parallax-shifts slightly against the anchored aurora — like the home-screen
///    icons. Still phone → clean icon lit from above. No gyroscope on the simulator (tilt stays at
///    rest there; the entrance and aurora still play).
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
            .overlay { glyphRelief() }
            .overlay { liquidGlassSurface() }
            .overlay { sheen(t: t) }
            .overlay { glassHighlight() }
            .overlay { innerRimLine() } // inner edge line, clipped to icon boundary
            .clipShape(shape)
            .overlay { outerRimLine() } // outer edge line, unclipped — creates the double-line look
            // Slight parallax against the (anchored) aurora as the phone tilts — the tile reads as
            // floating above the glow, like the home-screen icon parallax. `.offset` shifts only the
            // rendered content, so the `.background` aura below stays put.
            .offset(x: tilt.roll * size * 0.025, y: tilt.pitch * size * 0.025)
            .background { aura(t: t) }
            // Whole logo tilts ±5° in 3D — shifting the angle-of-view of the raised glass edges.
            .rotation3DEffect(.degrees(tilt.pitch * 5), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees(tilt.roll * 5), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
    }

    private var logo: some View {
        Image(asset: Asset.Images.appLogo)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }

    // MARK: - Light model

    /// Smoothed tilt magnitude: 0 with the phone still, →1 as it tilts.
    private var tiltMagnitude: Double {
        min(1, (tilt.roll * tilt.roll + tilt.pitch * tilt.pitch).squareRoot())
    }

    /// The tilt-driven light-source angle shared by the rim speculars and the glyph bevel.
    /// The constant `+0.55` overhead bias keeps `atan2` well-defined at rest — the light sits at
    /// 12 o'clock on a still phone (instead of spinning on sensor noise) and swings smoothly toward
    /// the raised edge as the device tilts.
    private var lightAngle: Angle {
        Angle(radians: atan2(tilt.roll, -tilt.pitch + 0.55) - .pi / 2)
    }

    /// Unit vector pointing from the tile centre toward the light (screen coordinates, y down).
    private var lightVector: CGSize {
        CGSize(width: cos(lightAngle.radians), height: sin(lightAngle.radians))
    }

    // MARK: - Glyph liquid-glass bevel

    /// The specular bevel around the wolf-in-speech-bubble glyph: for each glyph layer
    /// (`appLogoBubble`, then `appLogoWolf` raised slightly higher) a thin white crescent hugs the
    /// lit edge and a dark crescent the far edge, so the glyph reads as raised glass. The crescents
    /// are built by shifting a tinted copy of the glyph toward/away from the light and punching the
    /// unshifted glyph back out (`.destinationOut`), leaving only the exposed edge. The light
    /// direction and bevel depth track the device tilt; at rest the glyph is lit softly from above.
    private func glyphRelief() -> some View {
        let mag = tiltMagnitude
        // Bevel depth in points: visible at rest, digs slightly deeper while the phone moves.
        let depth = size * (0.014 + 0.012 * mag)

        return ZStack {
            glyphBevel(asset: Asset.Images.appLogoBubble, depth: depth * 0.85, mag: mag, parallax: 0.010)
            glyphBevel(asset: Asset.Images.appLogoWolf, depth: depth * 1.15, mag: mag, parallax: 0.020)
        }
        .allowsHitTesting(false)
    }

    /// Light + shade crescents for one glyph layer. `parallax` staggers the layers' drift with the
    /// tilt (the wolf rides higher than the bubble), keeping the depths distinct.
    private func glyphBevel(asset: ImageAsset, depth: CGFloat, mag: Double, parallax: CGFloat) -> some View {
        ZStack {
            // Specular crescent on the lit edge.
            glyphCrescent(asset: asset,
                          color: .white,
                          offset: CGSize(width: lightVector.width * depth, height: lightVector.height * depth))
                .opacity(0.55 + 0.30 * mag)
                .blendMode(.screen)
            // Shade crescent on the far edge — sells the raised 3D relief.
            glyphCrescent(asset: asset,
                          color: .black,
                          offset: CGSize(width: -lightVector.width * depth * 0.8, height: -lightVector.height * depth * 0.8))
                .opacity(0.22 + 0.14 * mag)
        }
        .offset(x: tilt.roll * size * parallax, y: tilt.pitch * size * parallax)
    }

    /// A thin edge crescent: the glyph tinted `color`, shifted by `offset`, minus the glyph at rest —
    /// only the sliver of the shifted copy that clears the glyph's own silhouette survives.
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

    /// On iOS 26 the tile surface picks up the system's Liquid Glass material — the clear variant,
    /// so the icon artwork stays legible underneath and only gains the glassy specular response.
    /// Earlier OS versions rely purely on the layered bevel/rim/sheen treatment.
    @ViewBuilder
    private func liquidGlassSurface() -> some View {
        if #available(iOS 26.0, *) {
            shape
                .fill(Color.clear)
                .glassEffect(.clear, in: shape)
                .opacity(0.45)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Tile speculars

    /// A specular hotspot that slides across the glass as the device tilts — light catching a real
    /// glass surface. Driven purely by `CoreMotion`, so it's still when the phone is still (and
    /// sits centred on the simulator). Clipped to the logo by the caller's `.clipShape`.
    private func glassHighlight() -> some View {
        // Only catches the light while the phone is actually tilting; when still it fades to nothing
        // so it never pools as a bright spot in the centre of the icon.
        let mag = min(1, tiltMagnitude * 1.7)
        return RadialGradient(colors: [.white.opacity(0.4), .white.opacity(0.08), .clear],
                              center: .center, startRadius: 0, endRadius: size * 0.55)
            .frame(width: size, height: size)
            .offset(x: tilt.roll * size * 0.32, y: -tilt.pitch * size * 0.32)
            .opacity(mag)
            .blendMode(.screen)
            .allowsHitTesting(false)
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
                    startAngle: lightAngle,
                    endAngle: lightAngle + .degrees(360)),
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
                    startAngle: lightAngle,
                    endAngle: lightAngle + .degrees(360)),
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

    // MARK: - Aurora

    /// The Siri-style aurora halo behind the tile, spilling ~25% past its edges as a soft glow.
    /// Geometry and colour are pure functions of `t` (the `GuaAuroraGlow` approach), so the motion
    /// can't be cancelled by a parent re-render; `t == 0` (Reduce Motion / tests) gives a
    /// deterministic static glow identical to frame 0. iOS 18+ warps a `MeshGradient` whose interior
    /// control points orbit while edge hues travel around the halo; iOS 17 drifts radial blobs.
    @ViewBuilder
    private func aura(t: TimeInterval) -> some View {
        let phase = t * (2 * .pi / 18) // one full palette revolution every ~18s — calm, not frantic
        Group {
            if #available(iOS 18.0, *) {
                MeshGradient(width: 4,
                             height: 4,
                             points: GuaAuroraPalette.meshPoints(phase: phase),
                             colors: GuaAuroraPalette.meshColors(phase: phase),
                             smoothsColors: true)
            } else {
                GuaAuroraBlobsFallback(phase: phase, dimension: size * 1.5)
            }
        }
        .frame(width: size * 1.5, height: size * 1.5)
        .clipShape(Circle())
        .blur(radius: size * 0.24)
        .opacity(0.45)
        .allowsHitTesting(false)
    }
}

// MARK: - Aurora palette & mesh maths (from GuaAuroraGlow)

/// The `GuaAuroraGlow` palette: Gua green leading cyan / blue / purple / pink accents.
private enum GuaAuroraPalette {
    static let green = Color(red: 0.20, green: 0.95, blue: 0.55)
    static let cyan = Color(red: 0.10, green: 0.80, blue: 0.90)
    static let blue = Color(red: 0.30, green: 0.55, blue: 1.00)
    static let purple = Color(red: 0.62, green: 0.40, blue: 1.00)
    static let pink = Color(red: 1.00, green: 0.48, blue: 0.74)

    /// Ordered ring the edge vertices travel through, so hue clearly *travels* around the halo
    /// rather than just rotating a symmetric wheel.
    private static let cycle: [Color] = [green, cyan, blue, purple, pink]

    /// Colour at a continuous position `p` (in turns) around `cycle`, linearly interpolated.
    private static func ramp(_ p: Double) -> Color {
        let n = cycle.count
        let scaled = (p.truncatingRemainder(dividingBy: 1) + 1)
            .truncatingRemainder(dividingBy: 1) * Double(n)
        let i = Int(scaled) % n
        let frac = scaled - Double(Int(scaled))
        return mix(cycle[i], cycle[(i + 1) % n], frac)
    }

    private static func mix(_ a: Color, _ b: Color, _ f: Double) -> Color {
        let ca = a.resolvedRGB, cb = b.resolvedRGB
        let c = ca + (cb - ca) * max(0, min(1, f))
        return Color(red: c.x, green: c.y, blue: c.z)
    }

    /// 16 control points laid out row by row from [0,0] (top-left) to [1,1] (bottom-right).
    /// The 12 outer points are pinned to the frame edges so the halo always fills the circle with
    /// no transparent gaps; the 4 *interior* points orbit on phase-offset sinusoids, which warps
    /// the colour field asymmetrically — the visible, clearly-moving part of the effect.
    static func meshPoints(phase: Double) -> [SIMD2<Float>] {
        func wob(_ base: SIMD2<Float>, _ seed: Double, amp: Float) -> SIMD2<Float> {
            let dx = Float(sin(phase + seed)) * amp
            let dy = Float(cos(phase * 0.85 + seed * 1.7)) * amp
            return SIMD2<Float>(base.x + dx, base.y + dy)
        }
        let a: Float = 0.16 // interior wobble amplitude

        return [
            // row 0 (top edge, pinned)
            SIMD2(0.0, 0.0), SIMD2(0.33, 0.0), SIMD2(0.66, 0.0), SIMD2(1.0, 0.0),
            // row 1 (left/right pinned, two interior points orbit)
            SIMD2(0.0, 0.33),
            wob(SIMD2(0.33, 0.33), 0.0, amp: a),
            wob(SIMD2(0.66, 0.33), 2.1, amp: a),
            SIMD2(1.0, 0.33),
            // row 2
            SIMD2(0.0, 0.66),
            wob(SIMD2(0.33, 0.66), 4.2, amp: a),
            wob(SIMD2(0.66, 0.66), 1.0, amp: a),
            SIMD2(1.0, 0.66),
            // row 3 (bottom edge, pinned)
            SIMD2(0.0, 1.0), SIMD2(0.33, 1.0), SIMD2(0.66, 1.0), SIMD2(1.0, 1.0)
        ]
    }

    /// 16 colours, one per mesh vertex (row-major). Edge vertices each pull from `ramp` at a
    /// different, slowly-advancing offset, so hue travels *around* the halo. Interior vertices use
    /// the brightest greens/cyans (mostly hidden behind the logo, they keep the core luminous).
    static func meshColors(phase: Double) -> [Color] {
        // One turn of hue travel per ~18s; corners offset so colour sweeps around the ring.
        let p = phase / (2 * .pi)
        return [
            ramp(p + 0.00), ramp(p + 0.10), ramp(p + 0.20), ramp(p + 0.30), // top
            ramp(p + 0.92), green, cyan, ramp(p + 0.42), // upper-mid
            ramp(p + 0.80), cyan, green, ramp(p + 0.52), // lower-mid
            ramp(p + 0.70), ramp(p + 0.66), ramp(p + 0.60), ramp(p + 0.55) // bottom
        ]
    }
}

/// Pre-iOS-18 aurora: soft radial-gradient blobs that drift and breathe on phase-offset sinusoids.
/// Driven by the same `phase` (i.e. by `TimelineView`), so it animates reliably without
/// `repeatForever` and reads as the same flowing, asymmetric glow.
private struct GuaAuroraBlobsFallback: View {
    let phase: Double
    let dimension: CGFloat

    private struct Blob {
        let color: Color
        let seed: Double
        let radius: CGFloat
    }

    private var blobs: [Blob] {
        [
            Blob(color: GuaAuroraPalette.green, seed: 0.0, radius: 0.62),
            Blob(color: GuaAuroraPalette.cyan, seed: 1.7, radius: 0.50),
            Blob(color: GuaAuroraPalette.blue, seed: 3.1, radius: 0.46),
            Blob(color: GuaAuroraPalette.purple, seed: 4.6, radius: 0.42),
            Blob(color: GuaAuroraPalette.pink, seed: 5.9, radius: 0.40)
        ]
    }

    var body: some View {
        ZStack {
            GuaAuroraPalette.green.opacity(0.35) // base wash so there are no gaps
            ForEach(Array(blobs.enumerated()), id: \.offset) { _, blob in
                let driftX = CGFloat(cos(phase + blob.seed)) * 0.30
                let driftY = CGFloat(sin(phase * 0.85 + blob.seed * 1.3)) * 0.30
                let breathe = 0.85 + 0.15 * CGFloat(sin(phase * 1.2 + blob.seed))
                Circle()
                    .fill(RadialGradient(colors: [blob.color, blob.color.opacity(0)],
                                         center: .center,
                                         startRadius: 0,
                                         endRadius: dimension * blob.radius))
                    .frame(width: dimension * blob.radius * 2,
                           height: dimension * blob.radius * 2)
                    .scaleEffect(breathe)
                    .offset(x: dimension * driftX, y: dimension * driftY)
                    .blendMode(.plusLighter)
            }
        }
    }
}

private extension Color {
    /// Resolved sRGB components (0...1) as an `x/y/z = r/g/b` vector. Used only for interpolating
    /// between the fixed palette colours above, which are all defined in sRGB, so this is exact
    /// for them.
    var resolvedRGB: SIMD3<Double> {
        #if canImport(UIKit)
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD3(Double(r), Double(g), Double(b))
        #else
        return SIMD3(0, 0, 0)
        #endif
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
