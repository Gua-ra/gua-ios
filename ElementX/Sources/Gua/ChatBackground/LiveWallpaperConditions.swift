//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

/// The device-wide inputs of `WallpaperMotionPolicy`, shared by every live wallpaper.
@Observable
final class LiveWallpaperConditions {
    static let shared = LiveWallpaperConditions()
    
    private(set) var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    private(set) var thermalState = ProcessInfo.processInfo.thermalState
    /// Set once by a frame watchdog, after which every live wallpaper stays still until the app restarts.
    private(set) var hasSlowFrames = false
    /// Artworks that can't be drawn live on this device, because there is no Metal or their shader failed to compile.
    private(set) var unavailableArtworks: Set<ChatArtwork> = []
    
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    
    init() {
        // Both notifications arrive on whichever thread changed the state.
        NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.thermalState = ProcessInfo.processInfo.thermalState
            }
            .store(in: &cancellables)
    }
    
    func reportSlowFrames() {
        guard !hasSlowFrames else { return }
        MXLog.info("Live wallpapers stay still for this session: frames are too slow.")
        hasSlowFrames = true
    }
    
    func reportUnavailable(_ artwork: ChatArtwork) {
        unavailableArtworks.insert(artwork)
    }
    
    func policy(for artwork: ChatArtwork, isOnScreen: Bool, isCovered: Bool = false, reducesMotion: Bool) -> WallpaperMotionPolicy {
        WallpaperMotionPolicy(isOnScreen: isOnScreen,
                              isCovered: isCovered,
                              reducesMotion: reducesMotion,
                              isLowPowerModeEnabled: isLowPowerModeEnabled,
                              thermalState: thermalState,
                              hasSlowFrames: hasSlowFrames,
                              isRendererAvailable: !unavailableArtworks.contains(artwork))
    }
}
