//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

@testable import ElementX
import XCTest

@MainActor
class SpacesSettingTests: XCTestCase {
    private var appSettings: AppSettings!
    private var clientProxy: ClientProxyMock!

    override func setUp() {
        AppSettings.resetAllSettings()
        appSettings = AppSettings()
        clientProxy = ClientProxyMock(.init())
        clientProxy.setAccountDataTypeContentReturnValue = .success(())
    }

    override func tearDown() {
        AppSettings.resetAllSettings()
    }

    func testStoredValueIsCopiedToThisDevice() async {
        clientProxy.accountDataTypeReturnValue = .success(#"{"enabled":true}"#)

        await SpacesSetting(clientProxy: clientProxy, appSettings: appSettings).refresh(isInSpace: false)

        XCTAssertTrue(appSettings.spacesEnabled)
        XCTAssertFalse(clientProxy.setAccountDataTypeContentCalled)
    }

    func testStoredFalseIsKeptForAnAccountInASpace() async {
        appSettings.spacesEnabled = true
        clientProxy.accountDataTypeReturnValue = .success(#"{"enabled":false}"#)

        await SpacesSetting(clientProxy: clientProxy, appSettings: appSettings).refresh(isInSpace: true)

        XCTAssertFalse(appSettings.spacesEnabled)
        XCTAssertFalse(clientProxy.setAccountDataTypeContentCalled)
    }

    func testAccountInASpaceWithNoStoredValueStartsWithSpacesOn() async {
        clientProxy.accountDataTypeReturnValue = .success(nil)

        await SpacesSetting(clientProxy: clientProxy, appSettings: appSettings).refresh(isInSpace: true)

        XCTAssertTrue(appSettings.spacesEnabled)
        XCTAssertEqual(clientProxy.setAccountDataTypeContentReceivedArguments?.type, SpacesSetting.accountDataType)
        XCTAssertEqual(clientProxy.setAccountDataTypeContentReceivedArguments?.content, #"{"enabled":true}"#)
    }

    func testAccountWithoutSpacesAndNoStoredValueStaysOff() async {
        appSettings.spacesEnabled = true
        clientProxy.accountDataTypeReturnValue = .success(nil)

        await SpacesSetting(clientProxy: clientProxy, appSettings: appSettings).refresh(isInSpace: false)

        XCTAssertFalse(appSettings.spacesEnabled)
        XCTAssertFalse(clientProxy.setAccountDataTypeContentCalled)
    }

    func testFailedWriteKeepsThePreviousValue() async {
        clientProxy.setAccountDataTypeContentReturnValue = .failure(.forbiddenAccess)

        let result = await SpacesSetting(clientProxy: clientProxy, appSettings: appSettings).setEnabled(true)

        guard case .failure = result else {
            XCTFail("Expected the write to fail")
            return
        }
        XCTAssertFalse(appSettings.spacesEnabled)
    }
}
