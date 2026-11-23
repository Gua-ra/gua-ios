//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Compound
import SwiftUI

struct AnimatedImageSettingsSection: View {
    @Binding var playGifsAutomatically: Bool
    
    var body: some View {
        Section {
            ListRow(label: .plain(title: UntranslatedL10n.guaSettingsPlayGifsAutomatically,
                                  description: UntranslatedL10n.guaSettingsPlayGifsAutomaticallyDescription),
                    kind: .toggle($playGifsAutomatically))
        }
    }
}

extension MediaUploadQualitySettingsScreen_Previews {
    static let gifsPausedViewModel = {
        let userSettings = UserSettings.mock()
        userSettings.app.guaPlayGifsAutomatically = false
        return MediaUploadQualitySettingsScreenViewModel(userSettings: userSettings, analytics: AnalyticsServiceMock(.init()))
    }()
}
