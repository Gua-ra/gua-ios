//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import XCTest

@MainActor
class SettingsScreenViewModelTests: XCTestCase {
    var viewModel: SettingsScreenViewModelProtocol!
    var context: SettingsScreenViewModelType.Context!
    var clientProxy: ClientProxyMock!
    var appSettings: AppSettings!
    var cancellables = Set<AnyCancellable>()
    
    @MainActor override func setUpWithError() throws {
        cancellables.removeAll()
        AppSettings.resetAllSettings()
        appSettings = AppSettings()
        clientProxy = ClientProxyMock(.init(userID: ""))
        let userSession = UserSessionMock(.init(clientProxy: clientProxy))
        viewModel = SettingsScreenViewModel(userSession: userSession,
                                            appSettings: appSettings,
                                            spacesSetting: SpacesSetting(clientProxy: clientProxy, appSettings: appSettings),
                                            isBugReportServiceEnabled: true)
        context = viewModel.context
    }
    
    override func tearDown() {
        AppSettings.resetAllSettings()
    }

    @MainActor func testLogout() async throws {
        let deferred = deferFulfillment(viewModel.actions) { $0 == .logout }
        context.send(viewAction: .logout)
        try await deferred.fulfill()
    }

    func testReportBug() async throws {
        let deferred = deferFulfillment(viewModel.actions) { $0 == .reportBug }
        context.send(viewAction: .reportBug)
        try await deferred.fulfill()
    }
    
    func testAnalytics() async throws {
        let deferred = deferFulfillment(viewModel.actions) { $0 == .analytics }
        context.send(viewAction: .analytics)
        try await deferred.fulfill()
    }
    
    func testToggleSpacesWritesAccountDataOnce() async {
        let written = expectation(description: "The switch is written to account data")
        clientProxy.setAccountDataTypeContentClosure = { _, _ in
            written.fulfill()
            return .success(())
        }
        XCTAssertFalse(context.isSpacesEnabled)
        
        context.isSpacesEnabled = true
        context.send(viewAction: .toggleSpaces)
        await fulfillment(of: [written], timeout: 1)
        XCTAssertTrue(appSettings.spacesEnabled)
        
        // The device copy echoes back into the binding, which sends the action again.
        context.send(viewAction: .toggleSpaces)
        
        XCTAssertEqual(clientProxy.setAccountDataTypeContentCallsCount, 1)
        XCTAssertEqual(clientProxy.setAccountDataTypeContentReceivedArguments?.type, SpacesSetting.accountDataType)
        XCTAssertEqual(clientProxy.setAccountDataTypeContentReceivedArguments?.content, #"{"enabled":true}"#)
    }
}
