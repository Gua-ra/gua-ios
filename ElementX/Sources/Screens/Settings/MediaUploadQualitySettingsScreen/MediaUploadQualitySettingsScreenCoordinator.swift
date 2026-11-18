//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

struct MediaUploadQualitySettingsScreenCoordinatorParameters {
    let appSettings: AppSettings
    let analytics: AnalyticsService
}

final class MediaUploadQualitySettingsScreenCoordinator: CoordinatorProtocol {
    private var viewModel: MediaUploadQualitySettingsScreenViewModelProtocol
    
    init(parameters: MediaUploadQualitySettingsScreenCoordinatorParameters) {
        viewModel = MediaUploadQualitySettingsScreenViewModel(appSettings: parameters.appSettings, analytics: parameters.analytics)
    }
    
    func toPresentable() -> AnyView {
        AnyView(MediaUploadQualitySettingsScreen(context: viewModel.context))
    }
}
