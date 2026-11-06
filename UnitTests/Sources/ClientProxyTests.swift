//
// Copyright Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import MatrixRustSDK
import MatrixRustSDKMocks
import Testing

@MainActor
struct ClientProxyTests {
    private let client = ClientSDKMock(.init(userID: "@alice:matrix.org"))
    private let syncService = SyncServiceSDKMock(.init())
    private let reachabilitySubject = CurrentValueSubject<NetworkMonitorReachability, Never>(.reachable)
    private let syncStarts = PassthroughSubject<Void, Never>()
    
    init() {
        client.syncServiceReturnValue = SyncServiceBuilderSDKMock(.init(syncService: syncService))
        syncService.startClosure = { [syncStarts] in syncStarts.send(()) }
    }
    
    @Test
    func aNewClientWaitsToBeResumed() async throws {
        let deferredStart = deferFailure(syncStarts, timeout: .milliseconds(500)) { _ in true }
        let clientProxy = try await makeClientProxy()
        try await deferredStart.fulfill()
        #expect(!client.resumeCalled)
        
        await clientProxy.resumeServices()
        #expect(syncService.startCallsCount == 1)
    }
    
    @Test
    func theNetworkReturningLeavesAPausedClientPaused() async throws {
        let clientProxy = try await makeClientProxy()
        await clientProxy.resumeServices()
        await clientProxy.pauseServices()
        
        let deferredStart = deferFailure(syncStarts, timeout: .milliseconds(500)) { _ in true }
        reachabilitySubject.send(.unreachable)
        reachabilitySubject.send(.reachable)
        try await deferredStart.fulfill()
        
        #expect(client.resumeCallsCount == 1)
        #expect(client.pauseCallsCount == 1)
    }
    
    @Test
    func theNetworkReturningStartsTheSyncOfAnOfflineClient() async throws {
        reachabilitySubject.send(.unreachable)
        let clientProxy = try await makeClientProxy()
        await clientProxy.resumeServices()
        #expect(!syncService.startCalled)
        
        let deferredStart = deferFulfillment(syncStarts) { _ in true }
        reachabilitySubject.send(.reachable)
        try await deferredStart.fulfill()
    }
    
    @Test
    func aSyncErrorAfterPausingLeavesTheClientPaused() async throws {
        let clientProxy = try await makeClientProxy()
        await clientProxy.resumeServices()
        await clientProxy.pauseServices()
        
        let deferredStart = deferFailure(syncStarts, timeout: .seconds(1)) { _ in true }
        try #require(syncService.stateListenerReceivedListener).onUpdate(state: .error)
        try await deferredStart.fulfill()
        
        #expect(client.resumeCallsCount == 1)
    }
    
    @Test
    func aSyncErrorWhileRunningRestartsTheSync() async throws {
        let clientProxy = try await makeClientProxy()
        await clientProxy.resumeServices()
        
        let deferredStart = deferFulfillment(syncStarts) { _ in true }
        try #require(syncService.stateListenerReceivedListener).onUpdate(state: .error)
        try await deferredStart.fulfill()
    }
    
    private func makeClientProxy() async throws -> ClientProxy {
        let appSettings = AppSettings.volatile()
        appSettings.clientPausingAndResumingEnabled = true
        return try await ClientProxy(client: client,
                                     networkMonitor: NetworkMonitorMock(.init(reachabilityPublisher: reachabilitySubject.asCurrentValuePublisher())),
                                     userSettings: appSettings.userSettings(for: "@alice:matrix.org"),
                                     analyticsService: AnalyticsServiceMock(.init())) { _ in }
    }
}
