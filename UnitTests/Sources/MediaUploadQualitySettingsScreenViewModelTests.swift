//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import AnalyticsEvents
@testable import ElementX
import XCTest

@MainActor
class MediaUploadQualitySettingsScreenViewModelTests: XCTestCase {
    private var appSettings: AppSettings!
    private var analyticsClient: AnalyticsClientMock!
    private var viewModel: MediaUploadQualitySettingsScreenViewModelProtocol!
    private var context: MediaUploadQualitySettingsScreenViewModelType.Context {
        viewModel.context
    }
    
    @MainActor override func setUpWithError() throws {
        AppSettings.resetAllSettings()
        appSettings = AppSettings()
        analyticsClient = AnalyticsClientMock()
        analyticsClient.isRunning = true
        viewModel = MediaUploadQualitySettingsScreenViewModel(appSettings: appSettings,
                                                              analytics: AnalyticsService(client: analyticsClient, appSettings: appSettings))
    }
    
    override func tearDown() {
        AppSettings.resetAllSettings()
    }
    
    func testTogglingWritesTheSettingAndTracksIt() throws {
        XCTAssertTrue(context.optimizeMediaUploads)
        
        context.optimizeMediaUploads = false
        context.send(viewAction: .optimizeMediaUploadsChanged)
        
        XCTAssertFalse(appSettings.optimizeMediaUploads)
        let event = try XCTUnwrap(analyticsClient.captureReceivedEvent as? AnalyticsEvent.Interaction)
        XCTAssertEqual(event.name, .MobileSettingsOptimizeMediaUploadsDisabled)
    }
}
