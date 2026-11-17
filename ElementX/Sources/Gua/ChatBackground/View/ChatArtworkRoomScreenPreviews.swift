//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI

struct ChatArtworkRoomScreen_Previews: PreviewProvider, TestablePreview {
    static let staticViewModels = makeViewModels(.palmCoast)
    static let liveViewModels = makeViewModels(.glassDrops)
    static let composerViewModel = ComposerToolbarViewModel.mock()
    
    static var previews: some View {
        roomScreen(staticViewModels)
            .previewDisplayName("Static artwork")
        
        roomScreen(staticViewModels)
            .environment(\.colorScheme, .dark)
            .preferredColorScheme(.dark)
            .previewDisplayName("Static artwork dark")
        
        roomScreen(liveViewModels)
            .previewDisplayName("Live artwork")
        
        roomScreen(liveViewModels)
            .environment(\.colorScheme, .dark)
            .preferredColorScheme(.dark)
            .previewDisplayName("Live artwork dark")
    }
    
    static func roomScreen(_ viewModels: RoomScreen_Previews.ViewModels) -> some View {
        ElementNavigationStack {
            RoomScreen(context: viewModels.room.context,
                       timelineContext: viewModels.timeline.context,
                       composerToolbar: ComposerToolbar(context: composerViewModel.context))
        }
    }
    
    static func makeViewModels(_ artwork: ChatArtwork) -> RoomScreen_Previews.ViewModels {
        RoomScreen_Previews.makeViewModels(roomName: "Weekend plans",
                                           hasOngoingCall: false,
                                           timelineItems: TimelineFixtures.chatBackgroundShowcase,
                                           chatTheme: ChatTheme(wallpaper: .art(artwork), bubbles: artwork.bubbles))
    }
}
