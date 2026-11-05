//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Combine
@testable import ElementX
import Foundation
import Testing

@MainActor
final class SpacesSettingTests {
    private var store: VolatileUserDefaults!
    private var appSettings: AppSettings!
    private var clientProxy: ClientProxyMock!
    private var spaceService: SpaceServiceProxyMock!
    private var spacesSetting: SpacesSetting!
    
    init() {
        store = VolatileUserDefaults()
        appSettings = AppSettings(store: store)
        clientProxy = ClientProxyMock(.init())
        clientProxy.setAccountDataTypeContentReturnValue = .success(())
        spaceService = SpaceServiceProxyMock(.init())
        clientProxy.spaceService = spaceService
        spacesSetting = SpacesSetting(clientProxy: clientProxy, appSettings: appSettings)
    }
    
    @Test
    func storedValueIsCopiedToThisDevice() async {
        clientProxy.accountDataTypeReturnValue = .success(#"{"enabled":true}"#)
        
        await spacesSetting.refresh()
        
        #expect(appSettings.spacesEnabled)
        #expect(!clientProxy.setAccountDataTypeContentCalled)
    }
    
    @Test
    func storedFalseIsKeptForAnAccountInASpace() async {
        appSettings.spacesEnabled = true
        clientProxy.accountDataTypeReturnValue = .success(#"{"enabled":false}"#)
        joinASpace()
        
        await spacesSetting.refresh(afterSync: true)
        
        #expect(!appSettings.spacesEnabled)
        #expect(!clientProxy.setAccountDataTypeContentCalled)
    }
    
    @Test
    func accountInASpaceWithNoStoredValueStartsWithSpacesOn() async {
        clientProxy.accountDataTypeReturnValue = .success(nil)
        joinASpace()
        
        await spacesSetting.refresh(afterSync: true)
        
        #expect(appSettings.spacesEnabled)
        #expect(clientProxy.setAccountDataTypeContentReceivedArguments?.type == SpacesSetting.accountDataType)
        #expect(clientProxy.setAccountDataTypeContentReceivedArguments?.content == #"{"enabled":true}"#)
    }
    
    @Test
    func failedOneTimeWriteIsRetriedOnTheNextSyncThenNotRepeatedBeforeItSyncs() async {
        clientProxy.accountDataTypeReturnValue = .success(nil)
        joinASpace()
        var results: [Result<Void, ClientProxyError>] = [.failure(.forbiddenAccess), .success(())]
        clientProxy.setAccountDataTypeContentClosure = { _, _ in results.removeFirst() }
        
        await spacesSetting.refresh(afterSync: true)
        #expect(!appSettings.spacesEnabled)
        
        await spacesSetting.refresh(afterSync: true)
        #expect(appSettings.spacesEnabled)
        
        await spacesSetting.refresh(afterSync: true)
        #expect(appSettings.spacesEnabled)
        #expect(clientProxy.setAccountDataTypeContentCallsCount == 2, "A nil read while the echo is pending must not write again.")
    }
    
    @Test
    func failingOneTimeWriteNeverTurnsSpacesOn() async {
        clientProxy.accountDataTypeReturnValue = .success(nil)
        clientProxy.setAccountDataTypeContentReturnValue = .failure(.forbiddenAccess)
        joinASpace()
        var values: [Bool] = []
        let cancellable = appSettings.spacesEnabledPublisher.sink { values.append($0) }
        
        await spacesSetting.refresh(afterSync: true)
        await spacesSetting.refresh(afterSync: true)
        cancellable.cancel()
        
        #expect(clientProxy.setAccountDataTypeContentCallsCount == 2)
        #expect(values == [false], "The device copy must only change once the account holds the value.")
    }
    
    @Test
    func oneTimeWriteTurnsSpacesOnOnlyOnceStored() async {
        let gate = WriteGate()
        clientProxy.setAccountDataTypeContentClosure = { _, _ in await gate.write() }
        clientProxy.accountDataTypeReturnValue = .success(nil)
        joinASpace()
        
        let refresh = Task { await spacesSetting.refresh(afterSync: true) }
        await gate.waitForWriters(1)
        #expect(!appSettings.spacesEnabled)
        
        gate.release()
        await refresh.value
        #expect(appSettings.spacesEnabled)
    }
    
    @Test
    func accountWithoutSpacesStoresOffAsItsDefault() async {
        let gate = WriteGate()
        clientProxy.setAccountDataTypeContentClosure = { _, _ in await gate.write() }
        clientProxy.accountDataTypeReturnValue = .success(nil)
        appSettings.spacesEnabled = true
        
        let refresh = Task { await spacesSetting.refresh(afterSync: true) }
        await gate.waitForWriters(1)
        #expect(appSettings.spacesEnabled, "The device copy must only change once the account holds the value.")
        
        gate.release()
        await refresh.value
        #expect(!appSettings.spacesEnabled)
        
        await spacesSetting.refresh(afterSync: true)
        #expect(clientProxy.setAccountDataTypeContentCallsCount == 1)
        #expect(clientProxy.setAccountDataTypeContentReceivedArguments?.content == #"{"enabled":false}"#)
    }
    
    @Test
    func noDefaultIsDecidedBeforeASync() async {
        clientProxy.accountDataTypeReturnValue = .success(nil)
        joinASpace()
        
        await spacesSetting.refresh()
        
        #expect(!clientProxy.setAccountDataTypeContentCalled, "The stored value may not have synced yet.")
        #expect(!spaceService.topLevelJoinedSpacesCalled)
    }
    
    @Test
    func membershipIsReadWhenTheDefaultIsDecided() async {
        clientProxy.accountDataTypeReturnValue = .success(nil)
        #expect(spaceService.topLevelSpacesPublisher.value.isEmpty)
        joinASpace()
        
        await spacesSetting.refresh(afterSync: true)
        
        #expect(appSettings.spacesEnabled)
        #expect(clientProxy.setAccountDataTypeContentReceivedArguments?.content == #"{"enabled":true}"#)
    }
    
    @Test
    func readFailureAfterASyncWritesNothing() async {
        appSettings.spacesEnabled = true
        clientProxy.accountDataTypeReturnValue = .failure(.forbiddenAccess)
        joinASpace()
        
        await spacesSetting.refresh(afterSync: true)
        
        #expect(appSettings.spacesEnabled)
        #expect(!clientProxy.setAccountDataTypeContentCalled)
    }
    
    @Test
    func switchChangedDuringTheDecisionWins() async {
        let gate = SpacesReadGate()
        spaceService.topLevelJoinedSpacesClosure = { await gate.read() }
        clientProxy.accountDataTypeReturnValue = .success(nil)
        
        let refresh = Task { await spacesSetting.refresh(afterSync: true) }
        await gate.waitForReaders(1)
        await spacesSetting.setEnabled(false)
        gate.release(.mockJoinedSpaces)
        await refresh.value
        
        #expect(!appSettings.spacesEnabled)
        #expect(clientProxy.setAccountDataTypeContentCallsCount == 1)
        #expect(clientProxy.setAccountDataTypeContentReceivedArguments?.content == #"{"enabled":false}"#)
    }
    
    @Test
    func invalidatingDuringTheDecisionWritesNothing() async {
        let gate = SpacesReadGate()
        spaceService.topLevelJoinedSpacesClosure = { await gate.read() }
        clientProxy.accountDataTypeReturnValue = .success(nil)
        
        let refresh = Task { await spacesSetting.refresh(afterSync: true) }
        await gate.waitForReaders(1)
        spacesSetting.invalidate()
        gate.release(.mockJoinedSpaces)
        await refresh.value
        
        #expect(!appSettings.spacesEnabled)
        #expect(!clientProxy.setAccountDataTypeContentCalled)
    }
    
    @Test
    func newerValueFromAnotherPhoneWinsOnceTheEchoTimesOut() async {
        spacesSetting = SpacesSetting(clientProxy: clientProxy, appSettings: appSettings, echoTimeout: 0)
        
        await spacesSetting.setEnabled(true)
        clientProxy.accountDataTypeReturnValue = .success(#"{"enabled":false}"#)
        await spacesSetting.refresh(afterSync: true)
        
        #expect(!appSettings.spacesEnabled)
    }
    
    @Test
    func aSpaceJoinedAfterTheDefaultWasStoredDoesNotTurnSpacesOn() async {
        clientProxy.accountDataTypeReturnValue = .success(nil)
        await spacesSetting.refresh(afterSync: true)
        clientProxy.accountDataTypeReturnValue = .success(#"{"enabled":false}"#)
        joinASpace()
        
        await spacesSetting.refresh(afterSync: true)
        
        #expect(!appSettings.spacesEnabled)
        #expect(clientProxy.setAccountDataTypeContentCallsCount == 1)
    }
    
    @Test
    func failedWriteKeepsThePreviousValue() async {
        clientProxy.setAccountDataTypeContentReturnValue = .failure(.forbiddenAccess)
        
        let result = await spacesSetting.setEnabled(true)
        
        guard case .failure = result else {
            Issue.record("Expected the write to fail")
            return
        }
        #expect(!appSettings.spacesEnabled)
    }
    
    @Test
    func pendingWriteIsNotUndoneByAStaleRead() async {
        let gate = WriteGate()
        clientProxy.setAccountDataTypeContentClosure = { _, _ in await gate.write() }
        clientProxy.accountDataTypeReturnValue = .success(#"{"enabled":false}"#)
        
        let write = Task { await spacesSetting.setEnabled(true) }
        await gate.waitForWriters(1)
        
        await spacesSetting.refresh()
        #expect(appSettings.spacesEnabled, "A read while the write is in flight must not undo it.")
        
        gate.release()
        _ = await write.value
        
        await spacesSetting.refresh()
        #expect(appSettings.spacesEnabled, "A read before sync brings the write back must not undo it.")
        
        clientProxy.accountDataTypeReturnValue = .success(#"{"enabled":true}"#)
        await spacesSetting.refresh()
        #expect(appSettings.spacesEnabled)
        
        clientProxy.accountDataTypeReturnValue = .success(#"{"enabled":false}"#)
        await spacesSetting.refresh()
        #expect(!appSettings.spacesEnabled, "Once the write has synced, a change from another phone applies.")
    }
    
    @Test
    func failedWriteDoesNotUndoANewerRequest() async {
        let gate = WriteGate()
        clientProxy.setAccountDataTypeContentClosure = { _, _ in await gate.write() }
        
        let firstWrite = Task { await spacesSetting.setEnabled(true) }
        await gate.waitForWriters(1)
        let secondWrite = Task { await spacesSetting.setEnabled(true) }
        await Task.yield()
        
        gate.release(.failure(.forbiddenAccess))
        await gate.waitForWriters(1)
        #expect(appSettings.spacesEnabled, "The first write failed, but a newer request is pending.")
        
        gate.release()
        _ = await firstWrite.value
        _ = await secondWrite.value
        
        #expect(appSettings.spacesEnabled)
        #expect(clientProxy.setAccountDataTypeContentCallsCount == 2)
    }
    
    @Test
    func overlappingFailedWritesEndOnTheLastChoice() async {
        let gate = WriteGate()
        clientProxy.setAccountDataTypeContentClosure = { _, _ in await gate.write() }
        
        let turnOn = Task { await spacesSetting.setEnabled(true) }
        await gate.waitForWriters(1)
        let turnOff = Task { await spacesSetting.setEnabled(false) }
        await Task.yield()
        #expect(!appSettings.spacesEnabled)
        
        gate.release(.failure(.forbiddenAccess))
        await gate.waitForWriters(1)
        gate.release(.failure(.forbiddenAccess))
        _ = await turnOn.value
        _ = await turnOff.value
        
        #expect(!appSettings.spacesEnabled)
        #expect(clientProxy.setAccountDataTypeContentReceivedArguments?.content == #"{"enabled":false}"#)
    }
    
    @Test
    func confirmedWriteIsKeptWhenItsEchoIsLate() async {
        spacesSetting = SpacesSetting(clientProxy: clientProxy, appSettings: appSettings, echoTimeout: 0)
        clientProxy.accountDataTypeReturnValue = .success(nil)
        
        joinASpace()
        
        await spacesSetting.setEnabled(false)
        await spacesSetting.refresh(afterSync: true)
        
        #expect(!appSettings.spacesEnabled)
        #expect(clientProxy.setAccountDataTypeContentCallsCount == 1, "A nil read after a confirmed write must not trigger the one-time write.")
    }
    
    @Test
    func invalidatedSettingIgnoresLateResults() async {
        let gate = WriteGate()
        clientProxy.setAccountDataTypeContentClosure = { _, _ in await gate.write() }
        
        appSettings.spacesEnabled = true
        let write = Task { await spacesSetting.setEnabled(false) }
        await gate.waitForWriters(1)
        spacesSetting.invalidate()
        appSettings.resetSessionSpecificSettings()
        
        gate.release(.failure(.forbiddenAccess))
        _ = await write.value
        #expect(!appSettings.spacesEnabled)
        
        clientProxy.accountDataTypeReturnValue = .success(#"{"enabled":true}"#)
        await spacesSetting.refresh()
        #expect(!appSettings.spacesEnabled)
    }
    
    @Test
    func theSwitchSurvivesAnAppRestart() async {
        await spacesSetting.setEnabled(true)
        
        #expect(AppSettings(store: store).spacesEnabled, "A new AppSettings instance reads the persisted device copy.")
    }
    
    @Test
    func turningSpacesOffOnlyWritesThePreference() async {
        appSettings.spacesEnabled = true
        
        await spacesSetting.setEnabled(false)
        
        #expect(!appSettings.spacesEnabled)
        #expect(clientProxy.setAccountDataTypeContentReceivedArguments?.type == SpacesSetting.accountDataType)
        #expect(clientProxy.setAccountDataTypeContentReceivedArguments?.content == #"{"enabled":false}"#)
        #expect(!clientProxy.joinRoomViaCalled)
        #expect(!clientProxy.joinRoomAliasCalled)
    }
    
    @Test
    func signOutResetsTheDeviceCopy() {
        appSettings.spacesEnabled = true
        
        appSettings.resetSessionSpecificSettings()
        
        #expect(!appSettings.spacesEnabled)
    }
    
    private func joinASpace() {
        spaceService.topLevelJoinedSpacesReturnValue = .mockJoinedSpaces
    }
}

@MainActor
private final class SpacesReadGate {
    private var waiting: [CheckedContinuation<[SpaceServiceRoom], Never>] = []
    
    func read() async -> [SpaceServiceRoom] {
        await withCheckedContinuation { waiting.append($0) }
    }
    
    func waitForReaders(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<1000 {
            if waiting.count >= count {
                return
            }
            await Task.yield()
        }
        Issue.record("Expected \(count) pending reads, found \(waiting.count)", sourceLocation: sourceLocation)
    }
    
    func release(_ spaces: [SpaceServiceRoom], sourceLocation: SourceLocation = #_sourceLocation) {
        guard !waiting.isEmpty else {
            Issue.record("No membership read is waiting to be released.", sourceLocation: sourceLocation)
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
    
    func waitForWriters(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<1000 {
            if waiting.count >= count {
                return
            }
            await Task.yield()
        }
        Issue.record("Expected \(count) pending writes, found \(waiting.count)", sourceLocation: sourceLocation)
    }
    
    func release(_ result: Result<Void, ClientProxyError> = .success(()), sourceLocation: SourceLocation = #_sourceLocation) {
        guard !waiting.isEmpty else {
            Issue.record("No write is waiting to be released.", sourceLocation: sourceLocation)
            return
        }
        waiting.removeFirst().resume(returning: result)
    }
}
