//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import XCTest

@MainActor
class ModerationAndSafetySettingsScreenViewModelTests: XCTestCase {
    private var appSettings: AppSettings!
    private var viewModel: ModerationAndSafetySettingsScreenViewModelProtocol!
    private var context: ModerationAndSafetySettingsScreenViewModelType.Context {
        viewModel.context
    }
    
    @MainActor override func setUpWithError() throws {
        AppSettings.resetAllSettings()
        appSettings = AppSettings()
        viewModel = ModerationAndSafetySettingsScreenViewModel(userSession: UserSessionMock(.init()),
                                                               appSettings: appSettings,
                                                               userIndicatorController: UserIndicatorControllerMock())
    }
    
    override func tearDown() {
        AppSettings.resetAllSettings()
    }
    
    func testSharePresenceWritesTheSetting() {
        XCTAssertTrue(context.sharePresence)
        
        context.sharePresence = false
        
        XCTAssertFalse(appSettings.sharePresence)
    }
}
