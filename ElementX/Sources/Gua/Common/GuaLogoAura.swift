//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI

/// An "Apple-Intelligence / Siri / aurora"-style living glow drawn behind the app logo on the
/// welcome / phone-entry screen.
///
/// The motion is driven by `TimelineView(.animation)`, which redraws on every display-link frame
/// for as long as the view is on screen. Every frame's geometry is computed **purely** from
/// `context.date` — there is no `@State`, no `.onAppear`, and no `withAnimation(.repeatForever)`.
/// That is deliberate: the earlier `.repeatForever` approach frequently never started (or was
/// silently cancelled) when the authentication flow re-rendered the parent, so the logo just sat
/// there static. A `TimelineView` clock cannot be cancelled by a parent re-render, so the aura
/// animates reliably the entire time it is visible.
///
/// It is frame-filled and sits behind the opaque rounded-rect logo, so only the **outer** halo
/// that spills past the icon is visible — the design pushes saturated, asymmetric colour toward the
/// edges and keeps the (hidden) centre calm. Set `animated == false` (Reduce Motion) for a
/// tasteful, deterministic static glow.
struct GuaAuroraGlow: View {
    /// When `false` (e.g. Reduce Motion) the glow is drawn statically with no animation clock.
    let animated: Bool

    var body: some View {
        // Suppressed entirely while snapshot / UI tests run, so reference images stay deterministic
        // (matching the existing welcome-logo snapshot-gate convention).
        if ProcessInfo.isRunningTests {
            Color.clear
        } else {
            aura
        }
    }

    private var aura: some View {
        // A fixed reference instant so the static (Reduce Motion) render is deterministic and
        // identical to frame 0 of the animated version.
        let staticDate = Date(timeIntervalSinceReferenceDate: 0)

        return GeometryReader { geometry in
            let dimension = min(geometry.size.width, geometry.size.height)

            // One code path for both states: a *paused* timeline simply never advances its clock,
            // so the static glow is identical to frame 0 of the animated one (no parallel render
            // path to drift out of sync).
            // `SwiftUI.` qualifier is required: ElementX defines its own `TimelineView` (the message
            // timeline), which would otherwise shadow SwiftUI's animation-scheduling one here.
            SwiftUI.TimelineView(.animation(minimumInterval: animated ? nil : .infinity, paused: !animated)) { context in
                AuraCanvas(date: animated ? context.date : staticDate, dimension: dimension)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            // Soft round halo so colour bleeds well past the logo's edges as a glow.
            .clipShape(Circle())
            .blur(radius: dimension * 0.12)
            // Keep the glow gentle — a soft tint, not a saturated ring.
            .opacity(0.55)
        }
    }
}

// MARK: - Aura canvas (geometry is a pure function of `date`)

/// Draws one frame of the aura for a given instant. Computing everything from `date` (rather than
/// animatable `@State`) is what makes the motion robust: each frame is self-contained, so nothing
/// can leave it "stuck" at a single value the way a cancelled `repeatForever` animation can.
private struct AuraCanvas: View {
    let date: Date
    let dimension: CGFloat

    var body: some View {
        // Two decoupled clocks: a brisk ~4.5s orbit so the (now compact) halo clearly churns
        // frame-to-frame, and a calmer ~10s hue drift so the colour change stays gentle.
        let t = date.timeIntervalSinceReferenceDate
        let orbitPhase = t * (2 * .pi / 4.5)
        let huePhase = t * (2 * .pi / 10)

        if #available(iOS 18.0, *) {
            MeshGradient(width: 4,
                         height: 4,
                         points: AuraPalette.meshPoints(phase: orbitPhase),
                         colors: AuraPalette.meshColors(phase: huePhase),
                         smoothsColors: true)
        } else {
            // iOS 17 fallback: still TimelineView-driven (no repeatForever), so it animates
            // reliably too. Asymmetric radial blobs that drift and breathe out of phase.
            AuraBlobsFallback(phase: orbitPhase, dimension: dimension)
        }
    }
}

// MARK: - Palette & mesh maths

private enum AuraPalette {
    // Lead with Gua green, then cyan / blue / purple / pink accents — softened toward pastel
    // (mixed ~38% toward white) so the halo reads as a gentle tint rather than saturated neon.
    static let green = Color(red: 0.50, green: 0.97, blue: 0.72)
    static let cyan = Color(red: 0.44, green: 0.88, blue: 0.94)
    static let blue = Color(red: 0.57, green: 0.72, blue: 1.00)
    static let purple = Color(red: 0.76, green: 0.63, blue: 1.00)
    static let pink = Color(red: 1.00, green: 0.68, blue: 0.84)

    /// Ordered ring the corner/edge vertices travel through, so hue clearly *travels* around the
    /// halo rather than just rotating a symmetric wheel.
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
        let ra = a.resolvableComponents, rb = b.resolvableComponents
        let f = max(0, min(1, f))
        return Color(red: ra.r + (rb.r - ra.r) * f,
                     green: ra.g + (rb.g - ra.g) * f,
                     blue: ra.b + (rb.b - ra.b) * f)
    }

    // MARK: 4x4 mesh

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
        let a: Float = 0.22 // interior wobble amplitude (larger so the compact halo clearly moves)

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

// MARK: - iOS 17 fallback

/// Pre-iOS-18 aura: a stack of soft radial-gradient blobs that drift and breathe on phase-offset
/// sinusoids. Driven by the same `phase` (i.e. by `TimelineView`), so it animates reliably without
/// `repeatForever`. The result reads as the same flowing, asymmetric Siri glow.
private struct AuraBlobsFallback: View {
    let phase: Double
    let dimension: CGFloat

    private struct Blob {
        let color: Color
        let seed: Double
        let radius: CGFloat
    }

    private var blobs: [Blob] {
        [
            Blob(color: AuraPalette.green, seed: 0.0, radius: 0.62),
            Blob(color: AuraPalette.cyan, seed: 1.7, radius: 0.50),
            Blob(color: AuraPalette.blue, seed: 3.1, radius: 0.46),
            Blob(color: AuraPalette.purple, seed: 4.6, radius: 0.42),
            Blob(color: AuraPalette.pink, seed: 5.9, radius: 0.40)
        ]
    }

    var body: some View {
        ZStack {
            AuraPalette.green.opacity(0.35) // base wash so there are no gaps
            ForEach(Array(blobs.enumerated()), id: \.offset) { _, blob in
                let driftX = CGFloat(cos(phase + blob.seed)) * 0.30
                let driftY = CGFloat(sin(phase * 0.85 + blob.seed * 1.3)) * 0.30
                let breathe = 0.85 + 0.15 * CGFloat(sin(phase * 1.2 + blob.seed))
                Circle()
                    .fill(
                        RadialGradient(colors: [blob.color, blob.color.opacity(0)],
                                       center: .center,
                                       startRadius: 0,
                                       endRadius: dimension * blob.radius)
                    )
                    .frame(width: dimension * blob.radius * 2,
                           height: dimension * blob.radius * 2)
                    .scaleEffect(breathe)
                    .offset(x: dimension * driftX, y: dimension * driftY)
                    .blendMode(.plusLighter)
            }
        }
    }
}

// MARK: - Colour component helper

private extension Color {
    /// Resolved sRGB components (0...1). Used only for interpolating between the fixed palette
    /// colours above, which are all defined in sRGB, so this is exact for them.
    var resolvableComponents: (r: Double, g: Double, b: Double) {
        #if canImport(UIKit)
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
        #else
        return (0, 0, 0)
        #endif
    }
}
