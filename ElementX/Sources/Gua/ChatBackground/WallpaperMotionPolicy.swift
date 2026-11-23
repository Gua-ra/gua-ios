//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Foundation

nonisolated struct WallpaperMotionPolicy: Equatable {
    enum Motion {
        case animating
        /// Holds the last frame and its time until it can animate again.
        case paused
        /// Shows the still image.
        case still
    }
    
    var isOnScreen = true
    var isAppActive = true
    /// A sheet, the message menu, a full-screen call or the app lock screen is over the chat, or the composer is up at the
    /// top bar and leaves no chat to see.
    var isCovered = false
    var reducesMotion = false
    var isLowPowerModeEnabled = false
    var thermalState = ProcessInfo.ThermalState.nominal
    var hasSlowFrames = false
    /// False without Metal or once the artwork's shader failed to compile.
    var isRendererAvailable = true
    
    var motion: Motion {
        if !isRendererAvailable || reducesMotion || isLowPowerModeEnabled || thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue || hasSlowFrames {
            return .still
        }
        if !isOnScreen || !isAppActive || isCovered {
            return .paused
        }
        return .animating
    }
    
    /// Tilt needs no shader, so an artwork without a renderer still tilts.
    var tiltMotion: Motion {
        var policy = self
        policy.isRendererAvailable = true
        return policy.motion
    }
    
    /// Adds what only the UIKit view can see; either side can stop motion, but neither can clear the other's.
    func including(isInWindow: Bool, isSceneActive: Bool, isCovered: Bool) -> WallpaperMotionPolicy {
        var policy = self
        policy.isOnScreen = isOnScreen && isInWindow
        policy.isAppActive = isAppActive && isSceneActive
        policy.isCovered = self.isCovered || isCovered
        return policy
    }
}

/// Judges GPU time, the wallpaper's own cost, so a stall elsewhere in the app delays frames without tripping it.
nonisolated struct WallpaperFrameWatchdog {
    static let framesPerSecond = 30
    static let tolerance: TimeInterval = 0.004
    static let limit = 1.5 / Double(framesPerSecond) + tolerance
    static let window: TimeInterval = 2
    /// With fewer frames than this in the window, one stray frame would decide the percentile.
    static let minimumFrames = 10
    
    private var frames: [(end: TimeInterval, duration: TimeInterval)] = []
    private(set) var hasTripped = false
    
    mutating func recordFrame(duration: TimeInterval, endingAt end: TimeInterval) -> Bool {
        guard !hasTripped else { return true }
        
        frames.append((end, duration))
        frames.removeAll { $0.end <= end - Self.window }
        guard frames.count >= Self.minimumFrames else { return false }
        
        let durations = frames.map(\.duration).sorted()
        let percentile90 = durations[Int((Double(durations.count) * 0.9).rounded(.up)) - 1]
        hasTripped = percentile90 > Self.limit
        return hasTripped
    }
    
    mutating func restart() {
        frames.removeAll()
    }
}
