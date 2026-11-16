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
    private var store: VolatileUserDefaults!
    private var userSettings: UserSettings!
    private var analyticsClient: AnalyticsClientMock!
    private var viewModel: MediaUploadQualitySettingsScreenViewModelProtocol!
    private var context: MediaUploadQualitySettingsScreenViewModelType.Context {
        viewModel.context
    }
    
    init() {
        store = VolatileUserDefaults()
        userSettings = AppSettings(store: store).userSettings(for: "@me:matrix.org")
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
    
    @Test
    func playGifsAutomaticallyIsOnByDefault() {
        #expect(context.playGifsAutomatically)
        #expect(userSettings.app.guaPlayGifsAutomatically)
    }
    
    @Test
    func togglingPlayGifsAutomaticallyPersists() {
        context.playGifsAutomatically = false
        
        #expect(!AppSettings(store: store).guaPlayGifsAutomatically)
        #expect(!context.playGifsAutomatically)
        #expect(userSettings.app.optimizeMediaUploads)
        
        context.playGifsAutomatically = true
        
        #expect(AppSettings(store: store).guaPlayGifsAutomatically)
    }
}
