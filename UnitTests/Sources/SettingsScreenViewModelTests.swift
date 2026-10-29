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
    var userIndicatorController: UserIndicatorControllerMock!
    var cancellables = Set<AnyCancellable>()
    
    @MainActor override func setUpWithError() throws {
        cancellables.removeAll()
        AppSettings.resetAllSettings()
        appSettings = AppSettings()
        clientProxy = ClientProxyMock(.init(userID: ""))
        userIndicatorController = UserIndicatorControllerMock()
        makeViewModel()
    }
    
    private func makeViewModel() {
        viewModel = SettingsScreenViewModel(userSession: UserSessionMock(.init(clientProxy: clientProxy)),
                                            appSettings: appSettings,
                                            spacesSetting: SpacesSetting(clientProxy: clientProxy, appSettings: appSettings),
                                            userIndicatorController: userIndicatorController,
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
    
    func testOpeningSettingsCopiesTheStoredSpacesValue() async throws {
        clientProxy.accountDataTypeReturnValue = .success(#"{"enabled":true}"#)
        let deferred = deferFulfillment(appSettings.$spacesEnabled) { $0 }
        
        makeViewModel()
        
        try await deferred.fulfill()
        XCTAssertFalse(clientProxy.setAccountDataTypeContentCalled)
    }
    
    func testOpeningSettingsDoesNotDecideTheSpacesDefault() async {
        clientProxy.spaceService = SpaceServiceProxyMock(.init(joinedSpaces: .mockJoinedSpaces))
        let read = expectation(description: "The stored value is read")
        read.assertForOverFulfill = false
        clientProxy.accountDataTypeClosure = { _ in
            read.fulfill()
            return .success(nil)
        }
        
        makeViewModel()
        await fulfillment(of: [read], timeout: 1)
        try? await Task.sleep(for: .milliseconds(100))
        
        XCTAssertFalse(appSettings.spacesEnabled)
        XCTAssertFalse(clientProxy.setAccountDataTypeContentCalled, "Only a sync response can prove the value is absent.")
    }
    
    func testFailedSpacesToggleMovesBackAndSaysSo() async throws {
        clientProxy.setAccountDataTypeContentReturnValue = .failure(.forbiddenAccess)
        
        let deferred = deferFulfillment(appSettings.$spacesEnabled, keyPath: \.self, transitionValues: [false, true, false])
        context.isSpacesEnabled = true
        context.send(viewAction: .toggleSpaces)
        try await deferred.fulfill()
        
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(context.isSpacesEnabled)
        XCTAssertTrue(userIndicatorController.submitIndicatorDelayReceivedInvocations.contains { $0.indicator.title == L10n.errorUnknown })
    }
}
