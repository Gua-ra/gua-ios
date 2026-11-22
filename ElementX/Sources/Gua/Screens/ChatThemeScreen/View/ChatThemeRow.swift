//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct ChatThemeRow: View {
    let theme: ChatTheme
    let canChange: Bool
    let action: () -> Void
    
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        // Members who cannot change the theme still open it to see a photo's credit.
        ListRow(label: .default(title: UntranslatedL10n.guaChatThemeTitle,
                                description: canChange ? nil : UntranslatedL10n.guaChatBackgroundRowNoPermission,
                                icon: CompoundIcon(customImage: Asset.Images.theme.swiftUIImage)),
                details: .title(theme.displayName(in: colorScheme)),
                kind: .navigationLink(action: action))
    }
}

extension ChatTheme {
    func displayName(in colorScheme: ColorScheme) -> String {
        switch wallpaper {
        case .none:
            isStock ? UntranslatedL10n.guaChatBackgroundValueDefault : bubbles.name(in: colorScheme)
        case .preset, .art, .photo:
            wallpaper.displayName
        }
    }
}

extension ChatBackground {
    var displayName: String {
        switch self {
        case .none:
            UntranslatedL10n.guaChatThemeNoWallpaper
        case .preset(let preset):
            preset.name
        case .art(let artwork):
            artwork.name
        case .photo:
            UntranslatedL10n.guaChatBackgroundValuePhoto
        }
    }
}
