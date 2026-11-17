//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

extension EnvironmentValues {
    /// Whether GIFs and animated stickers play by themselves, which the GIF autoplay switch in Media settings decides
    /// instead of the system's Auto-Play Animated Images. A GIF the user opens sets it to `true`.
    @Entry var playsAnimatedImages = true
}

extension AppCoordinatorProtocol {
    /// Only the app's own coordinator has settings for secondary windows to follow, so the test coordinators keep GIFs playing.
    var guaAppSettings: AppSettings? {
        nil
    }
}

extension View {
    /// Each window group applies this at its root, as SwiftUI shares no environment between windows.
    @ViewBuilder
    func playsAnimatedImages(following appSettings: AppSettings?) -> some View {
        if let appSettings {
            modifier(AnimatedImageAutoplayModifier(appSettings: appSettings))
        } else {
            self
        }
    }
}

private struct AnimatedImageAutoplayModifier: ViewModifier {
    let appSettings: AppSettings
    
    @State private var playsAnimatedImages: Bool
    
    init(appSettings: AppSettings) {
        self.appSettings = appSettings
        // The publisher only delivers after the first frame, which would animate a GIF the setting stills.
        _playsAnimatedImages = State(initialValue: appSettings.guaPlayGifsAutomatically)
    }
    
    func body(content: Content) -> some View {
        content
            .environment(\.playsAnimatedImages, playsAnimatedImages)
            .onReceive(appSettings.guaPlayGifsAutomaticallyPublisher) { playsAnimatedImages = $0 }
    }
}
