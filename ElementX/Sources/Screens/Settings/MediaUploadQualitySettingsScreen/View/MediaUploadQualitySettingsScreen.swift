//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct MediaUploadQualitySettingsScreen: View {
    @Bindable var context: MediaUploadQualitySettingsScreenViewModel.Context
    
    var body: some View {
        Form {
            Section {
                ListRow(label: .plain(title: L10n.screenAdvancedSettingsMediaCompressionTitle,
                                      description: L10n.screenAdvancedSettingsMediaCompressionDescription),
                        kind: .toggle($context.optimizeMediaUploads))
                    .onChange(of: context.optimizeMediaUploads) {
                        context.send(viewAction: .optimizeMediaUploadsChanged)
                    }
            }
        }
        .compoundList()
        .navigationTitle(UntranslatedL10n.commonMediaUploadQuality)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Previews

struct MediaUploadQualitySettingsScreen_Previews: PreviewProvider, TestablePreview {
    static let viewModel = MediaUploadQualitySettingsScreenViewModel(appSettings: ServiceLocator.shared.settings,
                                                                     analytics: ServiceLocator.shared.analytics)
    
    static var previews: some View {
        NavigationStack {
            MediaUploadQualitySettingsScreen(context: viewModel.context)
        }
    }
}
