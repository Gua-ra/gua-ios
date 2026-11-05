//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import AnalyticsEvents
@testable import ElementX
import Foundation
import Testing

@MainActor
final class MediaUploadQualitySettingsScreenViewModelTests {
    private var userSettings: UserSettings!
    private var analyticsClient: AnalyticsClientMock!
    private var viewModel: MediaUploadQualitySettingsScreenViewModelProtocol!
    private var context: MediaUploadQualitySettingsScreenViewModelType.Context {
        viewModel.context
    }
    
    init() {
        userSettings = .mock()
        analyticsClient = AnalyticsClientMock()
        analyticsClient.isRunning = true
        viewModel = MediaUploadQualitySettingsScreenViewModel(userSettings: userSettings,
                                                              analytics: AnalyticsService(client: analyticsClient, appSettings: userSettings.app))
    }
    
    @Test
    func togglingWritesTheSettingAndTracksIt() throws {
        #expect(context.optimizeMediaUploads)
        
        context.optimizeMediaUploads = false
        context.send(viewAction: .optimizeMediaUploadsChanged)
        
        #expect(!userSettings.app.optimizeMediaUploads)
        let event = try #require(analyticsClient.captureReceivedEvent as? AnalyticsEvent.Interaction)
        #expect(event.name == .MobileSettingsOptimizeMediaUploadsDisabled)
    }
}
