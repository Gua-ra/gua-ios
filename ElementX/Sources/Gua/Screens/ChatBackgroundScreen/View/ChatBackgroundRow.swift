//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct ChatBackgroundRow: View {
    let background: ChatBackground
    let canChange: Bool
    let action: () -> Void

    var body: some View {
        if canChange {
            ListRow(label: .default(title: UntranslatedL10n.guaChatBackgroundRowTitle, icon: icon),
                    details: .title(background.displayName),
                    kind: .navigationLink(action: action))
        } else {
            ListRow(label: .default(title: UntranslatedL10n.guaChatBackgroundRowTitle,
                                    description: UntranslatedL10n.guaChatBackgroundRowNoPermission,
                                    icon: icon),
                    details: .title(background.displayName),
                    kind: .button(action: action))
                .disabled(true)
        }
    }

    private var icon: CompoundIcon {
        CompoundIcon(customImage: Asset.Images.theme.swiftUIImage)
    }
}

extension ChatBackground {
    var displayName: String {
        switch self {
        case .none:
            UntranslatedL10n.guaChatBackgroundValueDefault
        case .preset(let preset):
            preset.name
        case .photo:
            UntranslatedL10n.guaChatBackgroundValuePhoto
        }
    }
}
