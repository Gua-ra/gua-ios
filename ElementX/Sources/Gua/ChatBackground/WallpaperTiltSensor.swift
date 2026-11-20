//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import CoreMotion
import SwiftUI

/// The tilt of an artwork's view, in the interface's frame; zero at rest.
@Observable
final class WallpaperParallax {
    /// Smaller changes move the still by hundredths of a point; skipping them keeps gyroscope noise on a phone at rest
    /// from redrawing the chat at the sensor's rate.
    static let minimumChange = 0.001
    
    /// What the still is moved by. It holds while a live frame covers the still.
    var tilt = SIMD2<Double>.zero
    /// The tilt last applied, which a live frame draws with; reading it never redraws the still.
    @ObservationIgnored private(set) var appliedTilt = SIMD2<Double>.zero
    
    /// Applies `newTilt` once it differs from the last applied tilt by at least `minimumChange`, and moves the still to it
    /// unless a live frame covers the still; returns whether it did.
    @discardableResult
    func apply(_ newTilt: SIMD2<Double>, movesStill: Bool = true) -> Bool {
        let change = newTilt - appliedTilt
        guard (change * change).sum().squareRoot() >= Self.minimumChange else { return false }
        appliedTilt = newTilt
        if movesStill {
            moveStillToAppliedTilt()
        }
        return true
    }
    
    /// Shows the still where the live frame that covered it was drawn.
    func moveStillToAppliedTilt() {
        if tilt != appliedTilt {
            tilt = appliedTilt
        }
    }
    
    /// A still condition resets the tilt, which then resumes from rest.
    func forgetAppliedTilt() {
        appliedTilt = .zero
    }
}

/// The gyroscope behind every wallpaper tilt: one motion manager, running only while a wallpaper subscribes.
final class WallpaperTiltSensor {
    static let shared = WallpaperTiltSensor()
    static let updateInterval: TimeInterval = 1.0 / 60
    
    private let manager = CMMotionManager()
    private var subscribers: [ObjectIdentifier: Subscriber] = [:]
    
    /// False without a gyroscope (the simulator) and in previews and tests, which never tilt.
    var isSupported: Bool {
        ChatLiveWallpaperView.isEnabled && manager.isDeviceMotionAvailable
    }
    
    /// Calls `onSample` with every rotation rate, bias corrected, until the subscriber unsubscribes or is released.
    func subscribe(_ subscriber: AnyObject, onSample: @escaping (_ rate: SIMD3<Double>, _ time: TimeInterval) -> Void) {
        guard isSupported else { return }
        subscribers[ObjectIdentifier(subscriber)] = Subscriber(object: subscriber, onSample: onSample)
        guard !manager.isDeviceMotionActive else { return }
        
        manager.deviceMotionUpdateInterval = Self.updateInterval
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            // A view released without unsubscribing, as when its window goes away, must not keep the sensor running.
            subscribers = subscribers.filter { $0.value.object != nil }
            guard !subscribers.isEmpty else {
                manager.stopDeviceMotionUpdates()
                return
            }
            
            let rate = SIMD3(motion.rotationRate.x, motion.rotationRate.y, motion.rotationRate.z)
            for subscriber in subscribers.values {
                subscriber.onSample(rate, motion.timestamp)
            }
        }
    }
    
    func unsubscribe(_ subscriber: AnyObject) {
        subscribers[ObjectIdentifier(subscriber)] = nil
        if subscribers.isEmpty, manager.isDeviceMotionActive {
            manager.stopDeviceMotionUpdates()
        }
    }
    
    private struct Subscriber {
        weak var object: AnyObject?
        let onSample: (_ rate: SIMD3<Double>, _ time: TimeInterval) -> Void
    }
}
