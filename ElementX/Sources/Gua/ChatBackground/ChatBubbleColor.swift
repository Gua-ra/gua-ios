//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

/// Colours only the outgoing bubble, in picker order.
nonisolated enum ChatBubbleColor: String, CaseIterable, Identifiable {
    /// The stock bubble, which is never written.
    case standard
    case green
    case teal
    case blue
    case purple
    case pink
    case orange
    case yellow
    case graphite
    
    var id: String {
        rawValue
    }
    
    var name: String {
        switch self {
        case .standard: UntranslatedL10n.guaChatThemeBubbleStandard
        case .green: UntranslatedL10n.guaChatThemeBubbleGreen
        case .teal: UntranslatedL10n.guaChatThemeBubbleTeal
        case .blue: UntranslatedL10n.guaChatThemeBubbleBlue
        case .purple: UntranslatedL10n.guaChatThemeBubblePurple
        case .pink: UntranslatedL10n.guaChatThemeBubblePink
        case .orange: UntranslatedL10n.guaChatThemeBubbleOrange
        case .yellow: UntranslatedL10n.guaChatThemeBubbleYellow
        case .graphite: UntranslatedL10n.guaChatThemeBubbleGraphite
        }
    }
    
    /// Increase Contrast keeps these: they already give the stock text colours the stock bubble's contrast.
    var hex: (light: UInt32, dark: UInt32)? {
        switch self {
        case .standard: nil
        case .green: (0xD9F4DD, 0x173826)
        case .teal: (0xD3F1EC, 0x123A38)
        case .blue: (0xDCE8FA, 0x18304F)
        case .purple: (0xE8E0F8, 0x30264D)
        case .pink: (0xF9DDE8, 0x4A1F36)
        case .orange: (0xFBE4D0, 0x4A2B14)
        case .yellow: (0xF7F0CC, 0x3F3612)
        case .graphite: (0xE1E4E9, 0x2F333A)
        }
    }
    
    @MainActor var outgoingColor: Color {
        guard let hex else { return .compound._bgBubbleOutgoing }
        return Color(UIColor { traits in
            UIColor(chatBackgroundHex: traits.userInterfaceStyle == .dark ? hex.dark : hex.light)
        })
    }
}

extension EnvironmentValues {
    @Entry var chatBubbleColor = ChatBubbleColor.standard
}

extension View {
    func chatTheme(_ theme: ChatTheme) -> some View {
        environment(\.chatBackgroundActive, !theme.wallpaper.isNone)
            .environment(\.chatBubbleColor, theme.bubble)
    }
}
