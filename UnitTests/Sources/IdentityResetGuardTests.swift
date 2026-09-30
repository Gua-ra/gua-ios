//
// Copyright Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import MatrixRustSDK
import XCTest

/// The guard's lifetime: marker before stop, stop before the reset, hold until the reset call has
/// returned whoever stopped waiting, and one terminal ordering however many times it is released.
class IdentityResetGuardTests: XCTestCase {
    private var events: [String] = []
    private var markerWrites: [Date?] = []
    private var syncRunning = true

    private struct SomeError: Error { }

    override func setUp() {
        events = []
        markerWrites = []
        syncRunning = true
    }

    // MARK: - acquire

    func testAcquireWritesTheMarkerBeforeStoppingAndStopsTwice() async {
        let guardUnderTest = makeGuard()

        await guardUnderTest.acquire { events.append("hold") }

        XCTAssertEqual(events, ["marker-write", "hold", "stop", "stop"])
        XCTAssertNotNil(markerWrites.first ?? nil)
        XCTAssertTrue(guardUnderTest.isHeld)
    }

    // MARK: - release

    func testReleasingAnIdleGuardRestoresSyncBeforeClearingTheMarkerOnce() async {
        let guardUnderTest = makeGuard()
        await guardUnderTest.acquire { }
        events = []

        await guardUnderTest.releaseIfIdle()
        await guardUnderTest.releaseIfIdle()

        XCTAssertEqual(events, ["hold-off", "start", "marker-clear"])
        XCTAssertFalse(guardUnderTest.isHeld)
    }

    /// The core invariant. A UI that stops waiting, a teardown, a second press: none of them may
    /// release a guard whose reset call is still running. The call's own return does.
    func testARunningResetKeepsTheGuardHeldUntilItReturns() async {
        let guardUnderTest = makeGuard()
        await guardUnderTest.acquire { }
        events = []
        let signal = TestSignal()
        let handle = IdentityResetHandleSDKMock()
        handle.resetAuthClosure = { _ in await signal.wait() }

        let operation = guardUnderTest.runReset(handle, auth: nil)

        // The UI's ceiling fires; nothing about the guard changes.
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(guardUnderTest.isHeld)
        XCTAssertNotNil(guardUnderTest.inFlightReset)
        XCTAssertFalse(events.contains("start"))
        XCTAssertFalse(events.contains("marker-clear"))

        // Teardown asks; the guard declines while the call runs.
        await guardUnderTest.releaseIfIdle()
        XCTAssertTrue(guardUnderTest.isHeld)
        XCTAssertEqual(events, [])

        // A second press joins the running call instead of starting another reset.
        let second = IdentityResetHandleSDKMock()
        _ = guardUnderTest.runReset(second, auth: nil)
        XCTAssertEqual(second.resetAuthCallsCount, 0)

        signal.fire()
        let result = await operation.value
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertNoThrow(try result.get())
        XCTAssertEqual(handle.resetAuthCallsCount, 1)
        XCTAssertEqual(events, ["landed", "hold-off", "start", "marker-clear", "provision"])
        XCTAssertFalse(guardUnderTest.isHeld)

        await guardUnderTest.releaseIfIdle()
        XCTAssertEqual(events.filter { $0 == "start" }.count, 1, "release is idempotent")
    }

    func testAFailedResetReleasesOnceAndProvisionsNothing() async {
        let guardUnderTest = makeGuard()
        await guardUnderTest.acquire { }
        events = []
        let handle = IdentityResetHandleSDKMock()
        handle.resetAuthThrowableError = SomeError()

        let result = await guardUnderTest.runReset(handle, auth: nil).value
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertThrowsError(try result.get())
        XCTAssertEqual(events, ["hold-off", "start", "marker-clear"])
        XCTAssertFalse(guardUnderTest.isHeld)
    }

    /// Sync is restored before the marker clears, so there is never a stopped sync without a marker.
    func testTheMarkerOutlivesTheStoppedSync() async throws {
        let guardUnderTest = makeGuard()
        await guardUnderTest.acquire { }
        events = []

        await guardUnderTest.releaseIfIdle()

        let start = try XCTUnwrap(events.firstIndex(of: "start"))
        let clear = try XCTUnwrap(events.firstIndex(of: "marker-clear"))
        XCTAssertLessThan(start, clear)
        XCTAssertEqual(markerWrites.last ?? Date(), nil)
    }

    // MARK: - deinit is an anomaly path, not a release path

    func testDeallocationAfterAReleaseStartsNothingTwice() async {
        var guardUnderTest: IdentityResetGuard? = makeGuard()
        await guardUnderTest?.acquire { }
        await guardUnderTest?.releaseIfIdle()

        guardUnderTest = nil
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(events.filter { $0 == "start" }.count, 1)
        XCTAssertEqual(events.filter { $0 == "marker-clear" }.count, 1)
    }

    func testDeallocationWhileHeldClearsTheMarkerAndStartsNothing() async {
        var guardUnderTest: IdentityResetGuard? = makeGuard()
        await guardUnderTest?.acquire { }
        events = []

        guardUnderTest = nil
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(events, ["marker-clear"])
    }

    // MARK: - marker refresh

    func testTheMarkerIsRefreshedWhileHeldAndNotAfter() async {
        let guardUnderTest = makeGuard(refreshInterval: .milliseconds(40))
        await guardUnderTest.acquire { }

        try? await Task.sleep(for: .milliseconds(220))
        let writesWhileHeld = markerWrites.compactMap { $0 }.count
        XCTAssertGreaterThanOrEqual(writesWhileHeld, 3, "writes: \(markerWrites.count)")

        await guardUnderTest.releaseIfIdle()
        let writesAtRelease = markerWrites.count
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(markerWrites.count, writesAtRelease)
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

/// The gate every sync start passes through, at the request and again inside the task that reaches
/// the SDK.
class ClientProxySyncGateTests: XCTestCase {
    func testAHeldIdentityResetBlocksEveryStart() {
        XCTAssertFalse(ClientProxy.maySyncStart(identityResetHeld: true, hasEncounteredAuthError: false, isReachable: true))
        XCTAssertFalse(ClientProxy.maySyncStart(identityResetHeld: true, hasEncounteredAuthError: true, isReachable: false))
    }

    func testTheOrdinaryGuardsStillApply() {
        XCTAssertFalse(ClientProxy.maySyncStart(identityResetHeld: false, hasEncounteredAuthError: true, isReachable: true))
        XCTAssertFalse(ClientProxy.maySyncStart(identityResetHeld: false, hasEncounteredAuthError: false, isReachable: false))
        XCTAssertTrue(ClientProxy.maySyncStart(identityResetHeld: false, hasEncounteredAuthError: false, isReachable: true))
    }
}

/// Lets a test hold an async call open until it decides to let it finish.
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
