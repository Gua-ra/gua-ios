//
// Copyright Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import MatrixRustSDK
import MatrixRustSDKMocks
import Testing

final class IdentityResetGuardTests {
    private var events: [String] = []
    private var markerWrites: [Date?] = []
    private var syncRunning = true
    
    private struct SomeError: Error { }
    
    init() {
        events = []
        markerWrites = []
        syncRunning = true
    }
    
    // MARK: - acquire
    
    @Test
    func acquireWritesTheMarkerBeforeStoppingAndStopsTwice() async {
        let guardUnderTest = makeGuard()
        
        await guardUnderTest.acquire { events.append("hold") }
        
        #expect(events == ["marker-write", "hold", "stop", "stop"])
        #expect(markerWrites.first ?? nil != nil)
        #expect(guardUnderTest.isHeld)
    }
    
    // MARK: - release
    
    @Test
    func releasingAnIdleGuardRestoresSyncBeforeClearingTheMarkerOnce() async {
        let guardUnderTest = makeGuard()
        await guardUnderTest.acquire { }
        events = []
        
        await guardUnderTest.releaseIfIdle()
        await guardUnderTest.releaseIfIdle()
        
        #expect(events == ["hold-off", "start", "marker-clear"])
        #expect(!guardUnderTest.isHeld)
    }
    
    @Test
    func aRunningResetKeepsTheGuardHeldUntilItReturns() async {
        let guardUnderTest = makeGuard()
        await guardUnderTest.acquire { }
        events = []
        let signal = TestSignal()
        let handle = IdentityResetHandleSDKMock()
        handle.resetAuthClosure = { _ in await signal.wait() }
        
        let operation = guardUnderTest.runReset(handle, auth: .oAuth(session: "session"))
        
        try? await Task.sleep(for: .milliseconds(150))
        #expect(guardUnderTest.isHeld)
        #expect(guardUnderTest.inFlightReset != nil)
        #expect(!events.contains("start"))
        #expect(!events.contains("marker-clear"))
        
        await guardUnderTest.releaseIfIdle()
        #expect(guardUnderTest.isHeld)
        #expect(events == [])
        
        let second = IdentityResetHandleSDKMock()
        _ = guardUnderTest.runReset(second, auth: .oAuth(session: "session"))
        #expect(second.resetAuthCallsCount == 0)
        
        signal.fire()
        let result = await operation.value
        try? await Task.sleep(for: .milliseconds(100))
        
        #expect(throws: Never.self) {
            try result.get()
        }
        #expect(handle.resetAuthCallsCount == 1)
        #expect(events == ["landed", "hold-off", "start", "marker-clear", "provision"])
        #expect(!guardUnderTest.isHeld)
        
        await guardUnderTest.releaseIfIdle()
        #expect(events.filter { $0 == "start" }.count == 1, "release is idempotent")
    }
    
    @Test
    func aFailedResetReleasesOnceAndProvisionsNothing() async {
        let guardUnderTest = makeGuard()
        await guardUnderTest.acquire { }
        events = []
        let handle = IdentityResetHandleSDKMock()
        handle.resetAuthThrowableError = SomeError()
        
        let result = await guardUnderTest.runReset(handle, auth: .oAuth(session: "session")).value
        try? await Task.sleep(for: .milliseconds(100))
        
        #expect(throws: (any Error).self) {
            try result.get()
        }
        #expect(events == ["hold-off", "start", "marker-clear"])
        #expect(!guardUnderTest.isHeld)
    }
    
    @Test
    func theMarkerOutlivesTheStoppedSync() async throws {
        let guardUnderTest = makeGuard()
        await guardUnderTest.acquire { }
        events = []
        
        await guardUnderTest.releaseIfIdle()
        
        let start = try #require(events.firstIndex(of: "start"))
        let clear = try #require(events.firstIndex(of: "marker-clear"))
        #expect(start < clear)
        #expect(markerWrites.last ?? Date() == nil)
    }
    
    // MARK: - deinit
    
    @Test
    func deallocationAfterAReleaseStartsNothingTwice() async {
        var guardUnderTest: IdentityResetGuard? = makeGuard()
        await guardUnderTest?.acquire { }
        await guardUnderTest?.releaseIfIdle()
        
        guardUnderTest = nil
        try? await Task.sleep(for: .milliseconds(50))
        
        #expect(events.filter { $0 == "start" }.count == 1)
        #expect(events.filter { $0 == "marker-clear" }.count == 1)
    }
    
    @Test
    func deallocationWhileHeldClearsTheMarkerAndStartsNothing() async {
        var guardUnderTest: IdentityResetGuard? = makeGuard()
        await guardUnderTest?.acquire { }
        events = []
        
        guardUnderTest = nil
        try? await Task.sleep(for: .milliseconds(50))
        
        #expect(events == ["marker-clear"])
    }
    
    // MARK: - marker refresh
    
    @Test
    func theMarkerIsRefreshedWhileHeldAndNotAfter() async {
        let guardUnderTest = makeGuard(refreshInterval: .milliseconds(40))
        await guardUnderTest.acquire { }
        
        try? await Task.sleep(for: .milliseconds(220))
        let writesWhileHeld = markerWrites.compactMap { $0 }.count
        #expect(writesWhileHeld >= 3, "writes: \(markerWrites.count)")
        
        await guardUnderTest.releaseIfIdle()
        let writesAtRelease = markerWrites.count
        try? await Task.sleep(for: .milliseconds(150))
        #expect(markerWrites.count == writesAtRelease)
    }
    
    // MARK: - helpers
    
    private func makeGuard(refreshInterval: Duration = .seconds(30)) -> IdentityResetGuard {
        IdentityResetGuard(dependencies: .init(stopSync: { [weak self] in
                                                   self?.events.append("stop")
                                                   self?.syncRunning = false
                                               },
                                               startSync: { [weak self] in
                                                   self?.events.append("start")
                                                   self?.syncRunning = true
                                               },
                                               isSyncRunning: { [weak self] in self?.syncRunning ?? false },
                                               writeMarker: { [weak self] date in
                                                   self?.markerWrites.append(date)
                                                   self?.events.append(date == nil ? "marker-clear" : "marker-write")
                                               },
                                               resetLanded: { [weak self] in self?.events.append("landed") },
                                               provisionAfterReset: { [weak self] in self?.events.append("provision") },
                                               onReleased: { [weak self] in self?.events.append("hold-off") }),
                           refreshInterval: refreshInterval)
    }
}

final class ClientProxySyncGateTests {
    @Test
    func aHeldIdentityResetBlocksEveryStart() {
        #expect(!ClientProxy.maySyncStart(identityResetHeld: true, hasEncounteredAuthError: false, isReachable: true))
        #expect(!ClientProxy.maySyncStart(identityResetHeld: true, hasEncounteredAuthError: true, isReachable: false))
    }
    
    @Test
    func theOrdinaryGuardsStillApply() {
        #expect(!ClientProxy.maySyncStart(identityResetHeld: false, hasEncounteredAuthError: true, isReachable: true))
        #expect(!ClientProxy.maySyncStart(identityResetHeld: false, hasEncounteredAuthError: false, isReachable: false))
        #expect(ClientProxy.maySyncStart(identityResetHeld: false, hasEncounteredAuthError: false, isReachable: true))
    }
}

final class TestSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var continuation: CheckedContinuation<Void, Never>?
    
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if fired {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
    
    func fire() {
        lock.lock()
        fired = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}
