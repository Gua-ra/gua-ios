//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

@MainActor
final class ModerationAndSafetySettingsScreenViewModelTests {
    private var userSettings: UserSettings!
    private var viewModel: ModerationAndSafetySettingsScreenViewModelProtocol!
    private var context: ModerationAndSafetySettingsScreenViewModelType.Context {
        viewModel.context
    }
    
    init() {
        userSettings = .mock()
        viewModel = ModerationAndSafetySettingsScreenViewModel(userSession: UserSessionMock(.init(userSettings: userSettings)),
                                                               userIndicatorController: UserIndicatorControllerMock())
    }
    
    @Test
    func sharePresenceWritesTheSetting() {
        #expect(context.sharePresence)
        
        context.sharePresence = false
        
        #expect(!userSettings.account.sharePresence)
    }
}
