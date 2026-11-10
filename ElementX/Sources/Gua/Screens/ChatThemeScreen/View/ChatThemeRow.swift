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
    
    var body: some View {
        if canChange {
            ListRow(label: .default(title: UntranslatedL10n.guaChatThemeTitle, icon: icon),
                    details: .title(theme.displayName),
                    kind: .navigationLink(action: action))
        } else {
            // Compound's disabled description colour would make the reason the hardest text on the row to read.
            ListRow(kind: .custom { NoPermissionRowContent(value: theme.displayName, icon: icon) })
        }
    }
    
    private var icon: CompoundIcon {
        CompoundIcon(customImage: Asset.Images.theme.swiftUIImage)
    }
}

private struct NoPermissionRowContent: View {
    let value: String
    let icon: CompoundIcon
    
    @ScaledMetric private var iconSize = Compound.supportsGlass ? 24.0 : 30
    
    var body: some View {
        HStack(spacing: 8) {
            HStack(alignment: Compound.supportsGlass ? .top : .center, spacing: ListRowPadding.labelIconSpacing) {
                icon
                    .foregroundStyle(.compound.iconTertiaryAlpha)
                    .frame(width: iconSize, height: iconSize)
                    .background(Compound.supportsGlass ? .clear : Color.compound._bgSubtleSecondaryAlpha)
                    .clipShape(RoundedRectangle(cornerRadius: Compound.supportsGlass ? 0 : 8))
                    .padding(.vertical, Compound.supportsGlass ? -1 : -4)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(UntranslatedL10n.guaChatThemeTitle)
                        .font(.compound.bodyLG)
                        .foregroundStyle(.compound.textDisabled)
                    Text(UntranslatedL10n.guaChatBackgroundRowNoPermission)
                        .font(.compound.bodySM)
                        .foregroundStyle(.compound.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            Text(value)
                .font(.compound.bodyLG)
                .foregroundStyle(.compound.textSecondary)
        }
        .padding(ListRowPadding.insets)
        .accessibilityElement(children: .combine)
    }
}

extension ChatTheme {
    var displayName: String {
        switch wallpaper {
        case .none:
            isStock ? UntranslatedL10n.guaChatBackgroundValueDefault : bubble.name
        case .preset, .photo:
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
        case .photo:
            UntranslatedL10n.guaChatBackgroundValuePhoto
        }
    }
}
