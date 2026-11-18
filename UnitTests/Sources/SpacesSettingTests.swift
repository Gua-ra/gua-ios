//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Combine
@testable import ElementX
import XCTest

@MainActor
class SpacesSettingTests: XCTestCase {
    private var appSettings: AppSettings!
    private var clientProxy: ClientProxyMock!
    private var spaceService: SpaceServiceProxyMock!
    private var spacesSetting: SpacesSetting!

    override func setUp() {
        AppSettings.resetAllSettings()
        appSettings = AppSettings()
        clientProxy = ClientProxyMock(.init())
        clientProxy.setAccountDataTypeContentReturnValue = .success(())
        spaceService = SpaceServiceProxyMock(.init())
        clientProxy.spaceService = spaceService
        spacesSetting = SpacesSetting(clientProxy: clientProxy, appSettings: appSettings)
    }

    override func tearDown() {
        AppSettings.resetAllSettings()
    }

    func testStoredValueIsCopiedToThisDevice() async {
        clientProxy.accountDataTypeReturnValue = .success(#"{"enabled":true}"#)

        await spacesSetting.refresh()

        XCTAssertTrue(appSettings.spacesEnabled)
        XCTAssertFalse(clientProxy.setAccountDataTypeContentCalled)
    }

    func testStoredFalseIsKeptForAnAccountInASpace() async {
        appSettings.spacesEnabled = true
        clientProxy.accountDataTypeReturnValue = .success(#"{"enabled":false}"#)
        joinASpace()

        await spacesSetting.refresh(afterSync: true)

        XCTAssertFalse(appSettings.spacesEnabled)
        XCTAssertFalse(clientProxy.setAccountDataTypeContentCalled)
    }

    func testAccountInASpaceWithNoStoredValueStartsWithSpacesOn() async {
        clientProxy.accountDataTypeReturnValue = .success(nil)
        joinASpace()

        await spacesSetting.refresh(afterSync: true)

        XCTAssertTrue(appSettings.spacesEnabled)
        XCTAssertEqual(clientProxy.setAccountDataTypeContentReceivedArguments?.type, SpacesSetting.accountDataType)
        XCTAssertEqual(clientProxy.setAccountDataTypeContentReceivedArguments?.content, #"{"enabled":true}"#)
    }

    func testFailedOneTimeWriteIsRetriedOnTheNextSyncThenNotRepeatedBeforeItSyncs() async {
        clientProxy.accountDataTypeReturnValue = .success(nil)
        joinASpace()
        var results: [Result<Void, ClientProxyError>] = [.failure(.forbiddenAccess), .success(())]
        clientProxy.setAccountDataTypeContentClosure = { _, _ in results.removeFirst() }

        await spacesSetting.refresh(afterSync: true)
        XCTAssertFalse(appSettings.spacesEnabled)

        await spacesSetting.refresh(afterSync: true)
        XCTAssertTrue(appSettings.spacesEnabled)

        await spacesSetting.refresh(afterSync: true)
        XCTAssertTrue(appSettings.spacesEnabled)
        XCTAssertEqual(clientProxy.setAccountDataTypeContentCallsCount, 2, "A nil read while the echo is pending must not write again.")
    }

    func testFailingOneTimeWriteNeverTurnsSpacesOn() async {
        clientProxy.accountDataTypeReturnValue = .success(nil)
        clientProxy.setAccountDataTypeContentReturnValue = .failure(.forbiddenAccess)
        joinASpace()
        var values: [Bool] = []
        let cancellable = appSettings.$spacesEnabled.sink { values.append($0) }
        
        await spacesSetting.refresh(afterSync: true)
        await spacesSetting.refresh(afterSync: true)
        cancellable.cancel()
        
        XCTAssertEqual(clientProxy.setAccountDataTypeContentCallsCount, 2)
        XCTAssertEqual(values, [false], "The device copy must only change once the account holds the value.")
    }
    
    func testOneTimeWriteTurnsSpacesOnOnlyOnceStored() async {
        let gate = WriteGate()
        clientProxy.setAccountDataTypeContentClosure = { _, _ in await gate.write() }
        clientProxy.accountDataTypeReturnValue = .success(nil)
        joinASpace()
        
        let refresh = Task { await spacesSetting.refresh(afterSync: true) }
        await gate.waitForWriters(1)
        XCTAssertFalse(appSettings.spacesEnabled)
        
        gate.release()
        await refresh.value
        XCTAssertTrue(appSettings.spacesEnabled)
    }
    
    func testAccountWithoutSpacesStoresOffAsItsDefault() async {
        let gate = WriteGate()
        clientProxy.setAccountDataTypeContentClosure = { _, _ in await gate.write() }
        clientProxy.accountDataTypeReturnValue = .success(nil)
        appSettings.spacesEnabled = true

        let refresh = Task { await spacesSetting.refresh(afterSync: true) }
        await gate.waitForWriters(1)
        XCTAssertTrue(appSettings.spacesEnabled, "The device copy must only change once the account holds the value.")

        gate.release()
        await refresh.value
        XCTAssertFalse(appSettings.spacesEnabled)

        await spacesSetting.refresh(afterSync: true)
        XCTAssertEqual(clientProxy.setAccountDataTypeContentCallsCount, 1)
        XCTAssertEqual(clientProxy.setAccountDataTypeContentReceivedArguments?.content, #"{"enabled":false}"#)
    }

    func testNoDefaultIsDecidedBeforeASync() async {
        clientProxy.accountDataTypeReturnValue = .success(nil)
        joinASpace()

        await spacesSetting.refresh()

        XCTAssertFalse(clientProxy.setAccountDataTypeContentCalled, "The stored value may not have synced yet.")
        XCTAssertFalse(spaceService.topLevelJoinedSpacesCalled)
    }

    func testMembershipIsReadWhenTheDefaultIsDecided() async {
        clientProxy.accountDataTypeReturnValue = .success(nil)
        XCTAssertTrue(spaceService.joinedSpacesPublisher.value.isEmpty)
        joinASpace()

        await spacesSetting.refresh(afterSync: true)

        XCTAssertTrue(appSettings.spacesEnabled)
        XCTAssertEqual(clientProxy.setAccountDataTypeContentReceivedArguments?.content, #"{"enabled":true}"#)
    }

    func testReadFailureAfterASyncWritesNothing() async {
        appSettings.spacesEnabled = true
        clientProxy.accountDataTypeReturnValue = .failure(.forbiddenAccess)
        joinASpace()

        await spacesSetting.refresh(afterSync: true)

        XCTAssertTrue(appSettings.spacesEnabled)
        XCTAssertFalse(clientProxy.setAccountDataTypeContentCalled)
    }

    func testSwitchChangedDuringTheDecisionWins() async {
        let gate = SpacesReadGate()
        spaceService.topLevelJoinedSpacesClosure = { await gate.read() }
        clientProxy.accountDataTypeReturnValue = .success(nil)

        let refresh = Task { await spacesSetting.refresh(afterSync: true) }
        await gate.waitForReaders(1)
        await spacesSetting.setEnabled(false)
        gate.release(.mockJoinedSpaces)
        await refresh.value

        XCTAssertFalse(appSettings.spacesEnabled)
        XCTAssertEqual(clientProxy.setAccountDataTypeContentCallsCount, 1)
        XCTAssertEqual(clientProxy.setAccountDataTypeContentReceivedArguments?.content, #"{"enabled":false}"#)
    }

    func testInvalidatingDuringTheDecisionWritesNothing() async {
        let gate = SpacesReadGate()
        spaceService.topLevelJoinedSpacesClosure = { await gate.read() }
        clientProxy.accountDataTypeReturnValue = .success(nil)

        let refresh = Task { await spacesSetting.refresh(afterSync: true) }
        await gate.waitForReaders(1)
        spacesSetting.invalidate()
        gate.release(.mockJoinedSpaces)
        await refresh.value

        XCTAssertFalse(appSettings.spacesEnabled)
        XCTAssertFalse(clientProxy.setAccountDataTypeContentCalled)
    }

    func testNewerValueFromAnotherPhoneWinsOnceTheEchoTimesOut() async {
        spacesSetting = SpacesSetting(clientProxy: clientProxy, appSettings: appSettings, echoTimeout: 0)

        await spacesSetting.setEnabled(true)
        clientProxy.accountDataTypeReturnValue = .success(#"{"enabled":false}"#)
        await spacesSetting.refresh(afterSync: true)

        XCTAssertFalse(appSettings.spacesEnabled)
    }

    func testASpaceJoinedAfterTheDefaultWasStoredDoesNotTurnSpacesOn() async {
        clientProxy.accountDataTypeReturnValue = .success(nil)
        await spacesSetting.refresh(afterSync: true)
        clientProxy.accountDataTypeReturnValue = .success(#"{"enabled":false}"#)
        joinASpace()

        await spacesSetting.refresh(afterSync: true)

        XCTAssertFalse(appSettings.spacesEnabled)
        XCTAssertEqual(clientProxy.setAccountDataTypeContentCallsCount, 1)
    }

    func testFailedWriteKeepsThePreviousValue() async {
        clientProxy.setAccountDataTypeContentReturnValue = .failure(.forbiddenAccess)

        let result = await spacesSetting.setEnabled(true)

        guard case .failure = result else {
            XCTFail("Expected the write to fail")
            return
        }
        XCTAssertFalse(appSettings.spacesEnabled)
    }

    func testPendingWriteIsNotUndoneByAStaleRead() async {
        let gate = WriteGate()
        clientProxy.setAccountDataTypeContentClosure = { _, _ in await gate.write() }
        clientProxy.accountDataTypeReturnValue = .success(#"{"enabled":false}"#)

        let write = Task { await spacesSetting.setEnabled(true) }
        await gate.waitForWriters(1)

        await spacesSetting.refresh()
        XCTAssertTrue(appSettings.spacesEnabled, "A read while the write is in flight must not undo it.")

        gate.release()
        _ = await write.value

        await spacesSetting.refresh()
        XCTAssertTrue(appSettings.spacesEnabled, "A read before sync brings the write back must not undo it.")

        clientProxy.accountDataTypeReturnValue = .success(#"{"enabled":true}"#)
        await spacesSetting.refresh()
        XCTAssertTrue(appSettings.spacesEnabled)

        clientProxy.accountDataTypeReturnValue = .success(#"{"enabled":false}"#)
        await spacesSetting.refresh()
        XCTAssertFalse(appSettings.spacesEnabled, "Once the write has synced, a change from another phone applies.")
    }

    func testFailedWriteDoesNotUndoANewerRequest() async {
        let gate = WriteGate()
        clientProxy.setAccountDataTypeContentClosure = { _, _ in await gate.write() }

        let firstWrite = Task { await spacesSetting.setEnabled(true) }
        await gate.waitForWriters(1)
        let secondWrite = Task { await spacesSetting.setEnabled(true) }
        await Task.yield()

        gate.release(.failure(.forbiddenAccess))
        await gate.waitForWriters(1)
        XCTAssertTrue(appSettings.spacesEnabled, "The first write failed, but a newer request is pending.")

        gate.release()
        _ = await firstWrite.value
        _ = await secondWrite.value

        XCTAssertTrue(appSettings.spacesEnabled)
        XCTAssertEqual(clientProxy.setAccountDataTypeContentCallsCount, 2)
    }

    func testOverlappingFailedWritesEndOnTheLastChoice() async {
        let gate = WriteGate()
        clientProxy.setAccountDataTypeContentClosure = { _, _ in await gate.write() }

        let turnOn = Task { await spacesSetting.setEnabled(true) }
        await gate.waitForWriters(1)
        let turnOff = Task { await spacesSetting.setEnabled(false) }
        await Task.yield()
        XCTAssertFalse(appSettings.spacesEnabled)

        gate.release(.failure(.forbiddenAccess))
        await gate.waitForWriters(1)
        gate.release(.failure(.forbiddenAccess))
        _ = await turnOn.value
        _ = await turnOff.value

        XCTAssertFalse(appSettings.spacesEnabled)
        XCTAssertEqual(clientProxy.setAccountDataTypeContentReceivedArguments?.content, #"{"enabled":false}"#)
    }

    func testConfirmedWriteIsKeptWhenItsEchoIsLate() async {
        spacesSetting = SpacesSetting(clientProxy: clientProxy, appSettings: appSettings, echoTimeout: 0)
        clientProxy.accountDataTypeReturnValue = .success(nil)
        
        joinASpace()
        
        await spacesSetting.setEnabled(false)
        await spacesSetting.refresh(afterSync: true)
        
        XCTAssertFalse(appSettings.spacesEnabled)
        XCTAssertEqual(clientProxy.setAccountDataTypeContentCallsCount, 1, "A nil read after a confirmed write must not trigger the one-time write.")
    }
    
    func testInvalidatedSettingIgnoresLateResults() async {
        let gate = WriteGate()
        clientProxy.setAccountDataTypeContentClosure = { _, _ in await gate.write() }
        
        appSettings.spacesEnabled = true
        let write = Task { await spacesSetting.setEnabled(false) }
        await gate.waitForWriters(1)
        spacesSetting.invalidate()
        AppSettings.resetSessionSpecificSettings()
        
        gate.release(.failure(.forbiddenAccess))
        _ = await write.value
        XCTAssertFalse(appSettings.spacesEnabled)
        
        clientProxy.accountDataTypeReturnValue = .success(#"{"enabled":true}"#)
        await spacesSetting.refresh()
        XCTAssertFalse(appSettings.spacesEnabled)
    }
    
    func testTheSwitchSurvivesAnAppRestart() async {
        await spacesSetting.setEnabled(true)
        
        XCTAssertTrue(AppSettings().spacesEnabled, "A new AppSettings instance reads the persisted device copy.")
    }
    
    func testTurningSpacesOffOnlyWritesThePreference() async {
        appSettings.spacesEnabled = true
        
        await spacesSetting.setEnabled(false)
        
        XCTAssertFalse(appSettings.spacesEnabled)
        XCTAssertEqual(clientProxy.setAccountDataTypeContentReceivedArguments?.type, SpacesSetting.accountDataType)
        XCTAssertEqual(clientProxy.setAccountDataTypeContentReceivedArguments?.content, #"{"enabled":false}"#)
        XCTAssertFalse(clientProxy.joinRoomViaCalled)
        XCTAssertFalse(clientProxy.joinRoomAliasCalled)
    }
    
    func testSignOutResetsTheDeviceCopy() {
        appSettings.spacesEnabled = true

        AppSettings.resetSessionSpecificSettings()

        XCTAssertFalse(appSettings.spacesEnabled)
    }
    
    private func joinASpace() {
        spaceService.topLevelJoinedSpacesReturnValue = .mockJoinedSpaces
    }
}

@MainActor
private final class SpacesReadGate {
    private var waiting: [CheckedContinuation<[SpaceRoomProxyProtocol], Never>] = []

    func read() async -> [SpaceRoomProxyProtocol] {
        await withCheckedContinuation { waiting.append($0) }
    }

    func waitForReaders(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 {
            if waiting.count >= count { return }
            await Task.yield()
        }
        XCTFail("Expected \(count) pending reads, found \(waiting.count)", file: file, line: line)
    }

    func release(_ spaces: [SpaceRoomProxyProtocol], file: StaticString = #filePath, line: UInt = #line) {
        guard !waiting.isEmpty else {
            XCTFail("No membership read is waiting to be released.", file: file, line: line)
            return
        }
        waiting.removeFirst().resume(returning: spaces)
    }
}

@MainActor
private final class WriteGate {
    private var waiting: [CheckedContinuation<Result<Void, ClientProxyError>, Never>] = []

    func write() async -> Result<Void, ClientProxyError> {
        await withCheckedContinuation { waiting.append($0) }
    }

    func waitForWriters(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 {
            if waiting.count >= count { return }
            await Task.yield()
        }
        XCTFail("Expected \(count) pending writes, found \(waiting.count)", file: file, line: line)
    }

    func release(_ result: Result<Void, ClientProxyError> = .success(()), file: StaticString = #filePath, line: UInt = #line) {
        guard !waiting.isEmpty else {
            XCTFail("No write is waiting to be released.", file: file, line: line)
            return
        }
        waiting.removeFirst().resume(returning: result)
    }
}
