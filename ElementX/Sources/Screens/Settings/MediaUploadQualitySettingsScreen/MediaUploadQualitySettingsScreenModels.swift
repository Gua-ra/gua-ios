//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

struct MediaUploadQualitySettingsScreenViewState: BindableState {
    var bindings: MediaUploadQualitySettingsScreenViewStateBindings
}

struct MediaUploadQualitySettingsScreenViewStateBindings {
    private let appSettings: AppSettings
    
    init(appSettings: AppSettings) {
        self.appSettings = appSettings
    }
    
    var optimizeMediaUploads: Bool {
        get { appSettings.optimizeMediaUploads }
        set { appSettings.optimizeMediaUploads = newValue }
    }
}

enum MediaUploadQualitySettingsScreenViewAction {
    case optimizeMediaUploadsChanged
}
