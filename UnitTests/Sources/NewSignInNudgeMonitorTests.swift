//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import XCTest

@MainActor
final class NewSignInNudgeMonitorTests: XCTestCase {
    private let userID = "@alice:gua.test"
    private let phoneID = "PHONE"
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private var clientProxy: ClientProxyMock!
    private var verificationState: CurrentValueSubject<SessionVerificationState, Never>!
    private var secureBackupController: SecureBackupControllerMock!
    private var appSettings: AppSettings!
    private var scheduler: ManualNewSignInNudgeScheduler!
    private var clock: NewSignInNudgeTestClock!
    private var notificationCenter: NotificationCenter!
    private var history: NewSignInNudgeHistory!
    private var isAppActive = true
    private var isIdle = true
    private var monitor: NewSignInNudgeMonitor!
    private var fixture: OwnDevicesFixture!

    override func setUp() async throws {
        OwnDevicesHTTPStub.reset()
        AppSettings.resetSessionSpecificSettings()
        IdentityResetPendingStore.clear(for: userID)

        clock = NewSignInNudgeTestClock(now: start)
        clientProxy = ClientProxyMock(.init(homeserver: "https://matrix.gua.test/", userID: userID, deviceID: phoneID))
        clientProxy.accessToken = "token-1"
        verificationState = .init(.verified)
        clientProxy.verificationStatePublisher = verificationState.asCurrentValuePublisher()
        secureBackupController = SecureBackupControllerMock(.init(recoveryState: .enabled))
        secureBackupController.settledRecoveryStateTimeoutReturnValue = .enabled
        secureBackupController.sdkRecoveryStateReturnValue = .enabled
        clientProxy.secureBackupController = secureBackupController

        appSettings = AppSettings()
        scheduler = ManualNewSignInNudgeScheduler()
        notificationCenter = NotificationCenter()
        history = NewSignInNudgeHistory()
        isAppActive = true
        isIdle = true

        fixture = OwnDevicesFixture(userID: userID, devices: [
            .init(id: phoneID, lastSeen: start, signedBySelfSigningKey: true),
            .init(id: "LAPTOP", lastSeen: start.addingTimeInterval(-30), signedBySelfSigningKey: true),
            .init(id: "OLDWEB", lastSeen: start.addingTimeInterval(-300)),
            .init(id: "NEWWEB", lastSeen: start.addingTimeInterval(-60))
        ])
        OwnDevicesHTTPStub.serve(devices: { [unowned self] in fixture.devicesJSON },
                                 keys: { [unowned self] in fixture.keysJSON })

        monitor = makeMonitor()
    }

    override func tearDown() async throws {
        monitor?.stop()
        IdentityResetPendingStore.clear(for: userID)
        appSettings?.setIdentityResetStartedAt(nil, forUserID: userID)
        AppSettings.resetSessionSpecificSettings()
        OwnDevicesHTTPStub.reset()
    }

    // MARK: - Candidate selection

    func testNudgesOnlyTheNewestRecentDeviceWithoutASelfSigningSignature() async throws {
        monitor.start()
        await runRound()

        let requests = OwnDevicesHTTPStub.requests
        XCTAssertEqual(requests.map(\.method), ["GET", "POST", "PUT"])

        XCTAssertEqual(requests[0].path, "/_matrix/client/v3/devices")
        XCTAssertEqual(requests[0].authorization, "Bearer token-1")

        XCTAssertEqual(requests[1].path, "/_matrix/client/v3/keys/query")
        XCTAssertEqual(requests[1].authorization, "Bearer token-1")
        XCTAssertEqual(requests[1].json, ["device_keys": [userID: [String]()]] as NSDictionary)

        let nudge = requests[2]
        let transactionID = try XCTUnwrap(nudge.path.split(separator: "/").last)
        XCTAssertEqual(nudge.path, "/_matrix/client/v3/sendToDevice/global.gua.verification.retry_request/\(transactionID)")
        XCTAssertFalse(transactionID.isEmpty)
        XCTAssertEqual(nudge.authorization, "Bearer token-1")
        XCTAssertEqual(nudge.json, ["messages": [userID: ["NEWWEB": ["from_device": phoneID]]]] as NSDictionary)
    }

    func testEachNudgeUsesAFreshTransactionID() async {
        monitor.start()
        await runRound()
        clock.now = start.addingTimeInterval(NewSignInNudgeMonitor.nudgeCooldown)
        await runRound()

        let paths = OwnDevicesHTTPStub.nudges.map(\.path)
        XCTAssertEqual(paths.count, 2)
        XCTAssertNotEqual(paths.first, paths.last)
    }

    func testDoesNotNudgeDevicesTheSelfSigningKeyHasSigned() async {
        fixture.devices = [.init(id: phoneID, lastSeen: start, signedBySelfSigningKey: true),
                           .init(id: "LAPTOP", lastSeen: start, signedBySelfSigningKey: true)]
        monitor.start()
        await runRound()

        XCTAssertEqual(OwnDevicesHTTPStub.requests.map(\.method), ["GET", "POST"])
    }

    func testDoesNotNudgeThisDevice() async {
        fixture.devices = [.init(id: phoneID, lastSeen: start)]
        monitor.start()
        await runRound()

        XCTAssertTrue(OwnDevicesHTTPStub.nudges.isEmpty)
    }

    func testDoesNotNudgeADehydratedDevice() async {
        fixture.devices = [.init(id: phoneID, lastSeen: start, signedBySelfSigningKey: true),
                           .init(id: "DEHYDRATED", lastSeen: start, dehydrated: true),
                           .init(id: "WEB", lastSeen: start.addingTimeInterval(-120), dehydrated: false)]
        monitor.start()
        await runRound()

        XCTAssertEqual(nudgedDevices, ["WEB"])
    }

    func testDoesNotNudgeADeviceNotSeenInTheLastTenMinutes() async {
        fixture.devices = [.init(id: phoneID, lastSeen: start, signedBySelfSigningKey: true),
                           .init(id: "STALE", lastSeen: start.addingTimeInterval(-NewSignInNudgeMonitor.recentSignInWindow - 1)),
                           .init(id: "NEVERSEEN", lastSeen: nil),
                           .init(id: "NOTLISTED", lastSeen: start, listedInDevices: false)]
        monitor.start()
        await runRound()

        XCTAssertEqual(OwnDevicesHTTPStub.requests.map(\.method), ["GET", "POST"])
    }

    func testNudgesADeviceSeenExactlyTenMinutesAgo() async {
        fixture.devices = [.init(id: phoneID, lastSeen: start, signedBySelfSigningKey: true),
                           .init(id: "WEB", lastSeen: start.addingTimeInterval(-NewSignInNudgeMonitor.recentSignInWindow))]
        monitor.start()
        await runRound()

        XCTAssertEqual(OwnDevicesHTTPStub.nudges.count, 1)
    }

    func testDoesNothingWhenTheAccountHasNoSelfSigningKey() async {
        fixture.selfSigningPublicKey = nil
        monitor.start()
        await runRound()

        XCTAssertEqual(OwnDevicesHTTPStub.requests.map(\.method), ["GET", "POST"])
    }

    func testSkipsADismissedDeviceAndNudgesTheNextNewest() async {
        appSettings.addDismissedSignInDeviceID("NEWWEB", forUserID: userID)
        monitor.start()
        await runRound()

        XCTAssertEqual(nudgedDevices, ["OLDWEB"])
    }

    func testDismissedDevicesArePerAccountAndClearedOnSignOut() {
        appSettings.addDismissedSignInDeviceID("WEB", forUserID: userID)
        appSettings.addDismissedSignInDeviceID("WEB2", forUserID: userID)

        XCTAssertEqual(appSettings.dismissedSignInDeviceIDs(forUserID: userID), ["WEB", "WEB2"])
        XCTAssertEqual(appSettings.dismissedSignInDeviceIDs(forUserID: "@bob:gua.test"), [])

        AppSettings.resetSessionSpecificSettings()

        XCTAssertEqual(appSettings.dismissedSignInDeviceIDs(forUserID: userID), [])
    }

    func testDoesNotNudgeADeviceThatSentARequestInTheLastTenMinutes() async {
        monitor.start()
        monitor.recordVerificationRequest(fromDeviceID: "NEWWEB")
        await runRound()

        XCTAssertEqual(nudgedDevices, ["OLDWEB"])

        fixture.devices = [.init(id: phoneID, lastSeen: start, signedBySelfSigningKey: true),
                           .init(id: "NEWWEB", lastSeen: start.addingTimeInterval(NewSignInNudgeMonitor.recentRequestWindow - 1))]
        clock.now = start.addingTimeInterval(NewSignInNudgeMonitor.recentRequestWindow - 1)
        await runRound()
        XCTAssertEqual(nudgedDevices, ["OLDWEB"])

        clock.now = start.addingTimeInterval(NewSignInNudgeMonitor.recentRequestWindow)
        await runRound()
        XCTAssertEqual(nudgedDevices, ["OLDWEB", "NEWWEB"])
    }

    // MARK: - Rate limits

    func testNudgesADeviceAtMostOnceEveryTwoMinutesAndThreeTimesInAll() async {
        fixture.devices = [.init(id: phoneID, lastSeen: start, signedBySelfSigningKey: true),
                           .init(id: "WEB", lastSeen: start)]
        monitor.start()

        await runRound(at: 0)
        XCTAssertEqual(OwnDevicesHTTPStub.nudges.count, 1)

        await runRound(at: 60)
        await runRound(at: 119)
        XCTAssertEqual(OwnDevicesHTTPStub.nudges.count, 1, "A device is nudged at most once every 120 s.")

        await runRound(at: 120)
        XCTAssertEqual(OwnDevicesHTTPStub.nudges.count, 2)

        await runRound(at: 240)
        XCTAssertEqual(OwnDevicesHTTPStub.nudges.count, 3)

        await runRound(at: 360)
        await runRound(at: 480)
        XCTAssertEqual(OwnDevicesHTTPStub.nudges.count, 3, "A device is nudged at most three times.")
    }

    func testTheNudgeLimitCountsFromAppLaunchNotFromSessionStart() async {
        fixture.devices = [.init(id: phoneID, lastSeen: start, signedBySelfSigningKey: true),
                           .init(id: "WEB", lastSeen: start)]
        monitor.start()
        await runRound(at: 0)
        await runRound(at: 120)
        await runRound(at: 240)
        XCTAssertEqual(OwnDevicesHTTPStub.nudges.count, 3)

        monitor.stop()
        scheduler = ManualNewSignInNudgeScheduler()
        monitor = makeMonitor()
        monitor.start()
        await runRound(at: 480)

        XCTAssertEqual(OwnDevicesHTTPStub.nudges.count, 3)
    }

    func testAFailedNudgeDoesNotCountTowardsTheLimits() async throws {
        fixture.devices = [.init(id: phoneID, lastSeen: start, signedBySelfSigningKey: true),
                           .init(id: "WEB", lastSeen: start)]
        let base = try XCTUnwrap(fixture)
        OwnDevicesHTTPStub.respond { request in
            switch request.method {
            case "GET": return (200, base.devicesJSON)
            case "POST": return (200, base.keysJSON)
            default: return (500, #"{"errcode":"M_UNKNOWN"}"#)
            }
        }
        monitor.start()

        await runRound(at: 0)
        await runRound(at: 60)
        await runRound(at: 119)
        XCTAssertEqual(OwnDevicesHTTPStub.nudges.count, 3, "A failed send leaves the cooldown and the limit untouched.")

        OwnDevicesHTTPStub.serve(devices: { base.devicesJSON }, keys: { base.keysJSON })
        await runRound(at: 180)
        XCTAssertEqual(OwnDevicesHTTPStub.nudges.count, 4)

        await runRound(at: 240)
        XCTAssertEqual(OwnDevicesHTTPStub.nudges.count, 4)
    }

    // MARK: - Gating

    func testDoesNothingWhileThisDeviceIsNotVerified() async {
        verificationState.send(.unverified)
        monitor.start()
        await runRound()

        XCTAssertTrue(OwnDevicesHTTPStub.requests.isEmpty)
    }

    func testDoesNothingUntilRecoveryHasSettledAsEnabled() async {
        secureBackupController.settledRecoveryStateTimeoutReturnValue = .incomplete
        monitor.start()
        await runRound()

        XCTAssertTrue(OwnDevicesHTTPStub.requests.isEmpty)
    }

    func testDoesNothingWhileTheSDKDisagreesThatRecoveryIsEnabled() async {
        secureBackupController.sdkRecoveryStateReturnValue = .incomplete
        monitor.start()
        await runRound()

        XCTAssertTrue(OwnDevicesHTTPStub.requests.isEmpty)
    }

    func testDoesNothingWhileAnIdentityResetIsPending() async {
        IdentityResetPendingStore.markPending(for: userID)
        monitor.start()
        await runRound()

        XCTAssertTrue(OwnDevicesHTTPStub.requests.isEmpty)
    }

    func testDoesNothingWhileAnIdentityResetIsRunning() async {
        appSettings.setIdentityResetStartedAt(start, forUserID: userID)
        monitor.start()
        await runRound()

        XCTAssertTrue(OwnDevicesHTTPStub.requests.isEmpty)
    }

    func testDoesNothingWhileSomethingIsPresented() async {
        isIdle = false
        monitor.start()
        await runRound()
        XCTAssertTrue(OwnDevicesHTTPStub.requests.isEmpty)

        isIdle = true
        await runRound()
        XCTAssertEqual(OwnDevicesHTTPStub.nudges.count, 1)
    }

    func testDoesNotNudgeWhenAModalAppearsWhileReading() async throws {
        let base = try XCTUnwrap(fixture)
        OwnDevicesHTTPStub.respond { [unowned self] request in
            switch request.path {
            case "/_matrix/client/v3/devices":
                return (200, base.devicesJSON)
            case "/_matrix/client/v3/keys/query":
                DispatchQueue.main.sync { self.isIdle = false }
                return (200, base.keysJSON)
            default:
                return (200, "{}")
            }
        }
        monitor.start()
        await runRound()

        XCTAssertEqual(OwnDevicesHTTPStub.requests.map(\.method), ["GET", "POST"])
    }

    func testDoesNothingWhileTheAppIsNotActive() async {
        isAppActive = false
        monitor.start()
        await settle()
        XCTAssertEqual(scheduler.liveEntries.map(\.delay), [NewSignInNudgeMonitor.settleDelay])

        scheduler.fire(NewSignInNudgeMonitor.settleDelay)
        await monitor.currentRound?.value

        XCTAssertTrue(OwnDevicesHTTPStub.requests.isEmpty)
    }

    // MARK: - Server errors

    func testUnauthorizedReadSkipsTheRoundAndTheNextRoundReadsAFreshToken() async {
        OwnDevicesHTTPStub.respond { _ in (401, #"{"errcode":"M_UNKNOWN_TOKEN","error":"Token expired"}"#) }
        monitor.start()
        await runRound()

        XCTAssertEqual(OwnDevicesHTTPStub.requests.map(\.method), ["GET"])
        XCTAssertFalse(clientProxy.logoutCalled)

        clientProxy.accessToken = "token-2"
        OwnDevicesHTTPStub.serve(devices: { [unowned self] in fixture.devicesJSON },
                                 keys: { [unowned self] in fixture.keysJSON })
        await runRound()

        let retried = OwnDevicesHTTPStub.requests.dropFirst()
        XCTAssertEqual(retried.map(\.method), ["GET", "POST", "PUT"])
        XCTAssertEqual(retried.map(\.authorization), Array(repeating: "Bearer token-2", count: 3))
    }

    func testUnauthorizedKeyQuerySendsNoNudge() async {
        let devicesJSON = fixture.devicesJSON
        OwnDevicesHTTPStub.respond { request in
            request.method == "GET" ? (200, devicesJSON) : (401, #"{"errcode":"M_UNKNOWN_TOKEN"}"#)
        }
        monitor.start()
        await runRound()

        XCTAssertEqual(OwnDevicesHTTPStub.requests.map(\.method), ["GET", "POST"])
        XCTAssertFalse(clientProxy.logoutCalled)
    }

    func testMalformedDeviceListSendsNoNudge() async {
        OwnDevicesHTTPStub.serve(devices: { #"{"unexpected": true}"# }, keys: { [unowned self] in fixture.keysJSON })
        monitor.start()
        await runRound()

        XCTAssertEqual(OwnDevicesHTTPStub.requests.map(\.method), ["GET"])
    }

    func testDoesNothingWithoutAnAccessToken() async {
        clientProxy.accessToken = nil
        monitor.start()
        await runRound()

        XCTAssertTrue(OwnDevicesHTTPStub.requests.isEmpty)
    }

    // MARK: - Scheduling

    func testFirstVerificationSchedulesOneRoundFiveSecondsLater() async {
        verificationState.send(.unverified)
        monitor.start()
        await settle()
        XCTAssertTrue(scheduler.liveEntries.filter { $0.delay == NewSignInNudgeMonitor.settleDelay }.isEmpty)

        verificationState.send(.verified)
        await settle()
        verificationState.send(.unverified)
        verificationState.send(.verified)
        await settle()

        let settled = scheduler.entries.filter { $0.delay == NewSignInNudgeMonitor.settleDelay }
        XCTAssertEqual(settled.count, 1, "Only the first verification in the session schedules a round.")
        XCTAssertFalse(settled[0].repeats)

        scheduler.fire(NewSignInNudgeMonitor.settleDelay)
        await monitor.currentRound?.value
        XCTAssertEqual(OwnDevicesHTTPStub.nudges.count, 1)
    }

    func testRoundsRepeatEveryMinuteOnlyWhileTheAppIsActive() async {
        monitor.start()
        await settle()
        XCTAssertEqual(scheduler.liveEntries.filter(\.repeats).map(\.delay), [NewSignInNudgeMonitor.roundInterval])

        notificationCenter.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertTrue(scheduler.liveEntries.isEmpty, "Nothing runs while the app is inactive or in the background.")

        notificationCenter.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        let live = scheduler.liveEntries
        XCTAssertEqual(live.filter(\.repeats).map(\.delay), [NewSignInNudgeMonitor.roundInterval])
        XCTAssertEqual(live.filter { !$0.repeats }.map(\.delay), [NewSignInNudgeMonitor.settleDelay])

        scheduler.fire(NewSignInNudgeMonitor.settleDelay)
        await monitor.currentRound?.value
        XCTAssertEqual(OwnDevicesHTTPStub.nudges.count, 1)
    }

    func testDoesNotRepeatWhenStartedInTheBackground() {
        isAppActive = false
        monitor.start()

        XCTAssertTrue(scheduler.liveEntries.filter(\.repeats).isEmpty)
    }

    func testStopCancelsEverything() async {
        monitor.start()
        await settle()
        XCTAssertFalse(scheduler.liveEntries.isEmpty)

        monitor.stop()
        XCTAssertTrue(scheduler.liveEntries.isEmpty)

        notificationCenter.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(scheduler.liveEntries.isEmpty)
    }

    // MARK: - Helpers

    private func makeMonitor() -> NewSignInNudgeMonitor {
        NewSignInNudgeMonitor(clientProxy: clientProxy,
                              appSettings: appSettings,
                              environment: .init(urlSession: OwnDevicesHTTPStub.makeSession(),
                                                 notificationCenter: notificationCenter,
                                                 scheduler: scheduler,
                                                 now: { [unowned self] in clock.now },
                                                 history: history),
                              isAppActive: { [unowned self] in isAppActive },
                              isIdle: { [unowned self] in isIdle })
    }

    /// Devices named in the nudges sent so far, in order.
    private var nudgedDevices: [String] {
        OwnDevicesHTTPStub.nudges.flatMap { nudge in
            let messages = nudge.json?["messages"] as? [String: [String: Any]]
            return messages?[userID].map { Array($0.keys) } ?? []
        }
    }

    private func runRound(at offset: TimeInterval? = nil) async {
        if let offset {
            clock.now = start.addingTimeInterval(offset)
        }
        scheduler.fire(NewSignInNudgeMonitor.roundInterval)
        await monitor.currentRound?.value
    }

    /// Lets main-queue deliveries (`receive(on:)`) run.
    private func settle() async {
        for _ in 0..<5 {
            await Task.yield()
        }
    }
}
