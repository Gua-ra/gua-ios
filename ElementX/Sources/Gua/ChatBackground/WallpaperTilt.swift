//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI

/// The tilt of a wallpaper from the gyroscope, each component in -1...1 in the device's own frame: (1, 0) is the viewer
/// to the right of the screen, (0, 1) the viewer above it.
nonisolated struct WallpaperTiltTracker {
    static let maxAngleDegrees = 20.0
    static let recentreSeconds: TimeInterval = 2
    static let smoothingSeconds: TimeInterval = 0.06
    static let maxStepSeconds: TimeInterval = 0.1
    
    private(set) var tilt = SIMD2<Double>.zero
    /// The viewer's direction in the device's frame: x right, y top, z out of the screen.
    private var viewer = SIMD3<Double>(0, 0, 1)
    private var lastSampleTime: TimeInterval?
    
    /// Takes one rotation rate around the device's axes, in rad/s with the right-hand rule. The first sample after a start
    /// only sets the clock.
    mutating func sample(rate: SIMD3<Double>, at time: TimeInterval) -> SIMD2<Double> {
        guard let lastSampleTime else {
            lastSampleTime = time
            return tilt
        }
        let step = min(max(time - lastSampleTime, 0), Self.maxStepSeconds)
        self.lastSampleTime = time
        
        // The viewer stays still in the world while the device turns, so in the device's frame it turns the other way.
        viewer = Self.normalized(viewer - Self.cross(rate, viewer) * step)
        let recentring = 1 - exp(-step / Self.recentreSeconds)
        viewer = Self.normalized(viewer * (1 - recentring) + SIMD3(0, 0, recentring))
        
        let fullTilt = sin(Self.maxAngleDegrees * .pi / 180)
        let target = SIMD2(tanh(viewer.x / fullTilt), tanh(viewer.y / fullTilt))
        let smoothing = 1 - exp(-step / Self.smoothingSeconds)
        tilt += (target - tilt) * smoothing
        return tilt
    }
    
    /// Keeps the tilt where it is until the next start.
    mutating func stop() {
        lastSampleTime = nil
    }
    
    private static func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }
    
    private static func normalized(_ vector: SIMD3<Double>) -> SIMD3<Double> {
        vector / (vector * vector).sum().squareRoot()
    }
}

/// How far the interface is turned from the device's natural portrait; a quarter turn is `landscapeRight`, the device
/// turned counter-clockwise.
nonisolated enum WallpaperScreenRotation: Int {
    case upright = 0
    case quarterTurn = 90
    case halfTurn = 180
    case threeQuarterTurn = 270
    
    init(_ orientation: UIInterfaceOrientation) {
        switch orientation {
        case .landscapeRight: self = .quarterTurn
        case .portraitUpsideDown: self = .halfTurn
        case .landscapeLeft: self = .threeQuarterTurn
        default: self = .upright
        }
    }
    
    /// A device tilt in the interface's frame.
    func interfaceTilt(_ deviceTilt: SIMD2<Double>) -> SIMD2<Double> {
        switch self {
        case .upright: deviceTilt
        case .quarterTurn: SIMD2(-deviceTilt.y, deviceTilt.x)
        case .halfTurn: -deviceTilt
        case .threeQuarterTurn: SIMD2(deviceTilt.y, -deviceTilt.x)
        }
    }
}

/// Where an artwork's still is drawn in a view where it tilts: aspect-filled around its anchor into a canvas `shift` larger
/// than the view on every side, which a full tilt moves by `shift`, so the edges never show.
nonisolated struct WallpaperStillLayout {
    static let shiftShare = 0.015
    
    let viewSize: CGSize
    let shift: CGFloat
    
    init(viewSize: CGSize) {
        self.viewSize = viewSize
        shift = Self.shiftShare * max(viewSize.width, viewSize.height)
    }
    
    /// The rect the still, its fallback and its grain are drawn in, in the view's coordinates.
    func canvasRect(at tilt: SIMD2<Double>) -> CGRect {
        let origin = CGPoint(x: -shift - CGFloat(tilt.x) * shift, y: -shift + CGFloat(tilt.y) * shift)
        let size = CGSize(width: viewSize.width + 2 * shift, height: viewSize.height + 2 * shift)
        return CGRect(origin: origin, size: size)
    }
    
    /// The still image's aspect-fill rect, in the view's coordinates.
    func imageRect(anchor: UnitPoint, at tilt: SIMD2<Double>) -> CGRect {
        let canvas = canvasRect(at: tilt)
        return ChatBackgroundPhotoLayout.rect(of: ChatArtwork.pixelSize, filling: canvas.size, alignX: anchor.x, alignY: anchor.y)
            .offsetBy(dx: canvas.minX, dy: canvas.minY)
    }
}
