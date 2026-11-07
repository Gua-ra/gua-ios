//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import Foundation
import Testing
import UIKit

@MainActor
final class NewSignInNudgeMonitorTests {
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
    private var fixture: OwnDevicesFixture! {
        get { OwnDevicesHTTPStub.fixture }
        set { OwnDevicesHTTPStub.fixture = newValue }
    }
    
    init() async throws {
        OwnDevicesHTTPStub.reset()
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
        
        appSettings = AppSettings.volatile()
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
        OwnDevicesHTTPStub.serveFixture()
        
        monitor = makeMonitor()
    }
    
    isolated deinit {
        monitor?.stop()
        IdentityResetPendingStore.clear(for: userID)
        appSettings?.resetSessionSpecificSettings()
        OwnDevicesHTTPStub.reset()
    }
    
    @Test
    func nudgesOnlyTheNewestRecentDeviceWithoutASelfSigningSignature() async throws {
        monitor.start()
        await runRound()
        
        let requests = OwnDevicesHTTPStub.requests
        #expect(requests.map(\.method) == ["GET", "POST", "PUT"])
        
        #expect(requests[0].path == "/_matrix/client/v3/devices")
        #expect(requests[0].authorization == "Bearer token-1")
        
        #expect(requests[1].path == "/_matrix/client/v3/keys/query")
        #expect(requests[1].authorization == "Bearer token-1")
        #expect(requests[1].json == ["device_keys": [userID: [String]()]] as NSDictionary)
        
        let nudge = requests[2]
        let transactionID = try #require(nudge.path.split(separator: "/").last)
        #expect(nudge.path == "/_matrix/client/v3/sendToDevice/global.gua.verification.retry_request/\(transactionID)")
        #expect(!transactionID.isEmpty)
        #expect(nudge.authorization == "Bearer token-1")
        #expect(nudge.json == ["messages": [userID: ["NEWWEB": ["from_device": phoneID]]]] as NSDictionary)
    }
    
    @Test
    func eachNudgeUsesAFreshTransactionID() async {
        monitor.start()
        await runRound()
        clock.now = start.addingTimeInterval(120)
        await runRound()
        
        let paths = OwnDevicesHTTPStub.nudges.map(\.path)
        #expect(paths.count == 2)
        #expect(paths.first != paths.last)
    }
    
    @Test
    func doesNotNudgeDevicesTheSelfSigningKeyHasSigned() async {
        fixture.devices = [.init(id: phoneID, lastSeen: start, signedBySelfSigningKey: true),
                           .init(id: "LAPTOP", lastSeen: start, signedBySelfSigningKey: true)]
        monitor.start()
        await runRound()
        
        #expect(OwnDevicesHTTPStub.requests.map(\.method) == ["GET", "POST"])
    }
    
    @Test
    func doesNotNudgeThisDevice() async {
        fixture.devices = [.init(id: phoneID, lastSeen: start)]
        monitor.start()
        await runRound()
        
        #expect(OwnDevicesHTTPStub.nudges.isEmpty)
    }
    
    @Test
    func doesNotNudgeADehydratedDevice() async {
        fixture.devices = [.init(id: phoneID, lastSeen: start, signedBySelfSigningKey: true),
                           .init(id: "DEHYDRATED", lastSeen: start, dehydrated: true),
                           .init(id: "WEB", lastSeen: start.addingTimeInterval(-120), dehydrated: false)]
        monitor.start()
        await runRound()
        
        #expect(nudgedDevices == ["WEB"])
    }
    
    @Test
    func doesNotNudgeADeviceNotSeenInTheLastTenMinutes() async {
        fixture.devices = [.init(id: phoneID, lastSeen: start, signedBySelfSigningKey: true),
                           .init(id: "STALE", lastSeen: start.addingTimeInterval(-601)),
                           .init(id: "NEVERSEEN", lastSeen: nil),
                           .init(id: "NOTLISTED", lastSeen: start, listedInDevices: false)]
        monitor.start()
        await runRound()
        
        #expect(OwnDevicesHTTPStub.requests.map(\.method) == ["GET", "POST"])
    }
    
    @Test
    func nudgesADeviceSeenExactlyTenMinutesAgo() async {
        fixture.devices = [.init(id: phoneID, lastSeen: start, signedBySelfSigningKey: true),
                           .init(id: "WEB", lastSeen: start.addingTimeInterval(-600))]
        monitor.start()
        await runRound()
        
        #expect(OwnDevicesHTTPStub.nudges.count == 1)
    }
    
    @Test
    func doesNothingWhenTheAccountHasNoSelfSigningKey() async {
        fixture.selfSigningPublicKey = nil
        monitor.start()
        await runRound()
        
        #expect(OwnDevicesHTTPStub.requests.map(\.method) == ["GET", "POST"])
    }
    
    @Test
    func skipsADismissedDeviceAndNudgesTheNextNewest() async {
        appSettings.addDismissedSignInDeviceID("NEWWEB", forUserID: userID)
        monitor.start()
        await runRound()
        
        #expect(nudgedDevices == ["OLDWEB"])
    }
    
    @Test
    func dismissedDevicesArePerAccountAndClearedOnSignOut() {
        appSettings.addDismissedSignInDeviceID("WEB", forUserID: userID)
        appSettings.addDismissedSignInDeviceID("WEB2", forUserID: userID)
        
        #expect(appSettings.dismissedSignInDeviceIDs(forUserID: userID) == ["WEB", "WEB2"])
        #expect(appSettings.dismissedSignInDeviceIDs(forUserID: "@bob:gua.test") == [])
        
        appSettings.resetSessionSpecificSettings()
        
        #expect(appSettings.dismissedSignInDeviceIDs(forUserID: userID) == [])
    }
    
    @Test
    func doesNotNudgeADeviceThatSentARequestInTheLastTenMinutes() async {
        monitor.start()
        monitor.recordVerificationRequest(fromDeviceID: "NEWWEB")
        await runRound()
        
        #expect(nudgedDevices == ["OLDWEB"])
        
        fixture.devices = [.init(id: phoneID, lastSeen: start, signedBySelfSigningKey: true),
                           .init(id: "NEWWEB", lastSeen: start.addingTimeInterval(599))]
        clock.now = start.addingTimeInterval(599)
        await runRound()
        #expect(nudgedDevices == ["OLDWEB"])
        
        clock.now = start.addingTimeInterval(600)
        await runRound()
        #expect(nudgedDevices == ["OLDWEB", "NEWWEB"])
    }
    
    @Test
    func nudgesADeviceAtMostOnceEveryTwoMinutesAndThreeTimesInAll() async {
        fixture.devices = [.init(id: phoneID, lastSeen: start, signedBySelfSigningKey: true),
                           .init(id: "WEB", lastSeen: start)]
        monitor.start()
        
        await runRound(at: 0)
        #expect(OwnDevicesHTTPStub.nudges.count == 1)
        
        await runRound(at: 60)
        await runRound(at: 119)
        #expect(OwnDevicesHTTPStub.nudges.count == 1, "A device is nudged at most once every 120 s.")
        
        await runRound(at: 120)
        #expect(OwnDevicesHTTPStub.nudges.count == 2)
        
        await runRound(at: 240)
        #expect(OwnDevicesHTTPStub.nudges.count == 3)
        
        await runRound(at: 360)
        await runRound(at: 480)
        #expect(OwnDevicesHTTPStub.nudges.count == 3, "A device is nudged at most three times.")
    }
    
    @Test
    func theNudgeLimitCountsFromAppLaunchNotFromSessionStart() async {
        fixture.devices = [.init(id: phoneID, lastSeen: start, signedBySelfSigningKey: true),
                           .init(id: "WEB", lastSeen: start)]
        monitor.start()
        await runRound(at: 0)
        await runRound(at: 120)
        await runRound(at: 240)
        #expect(OwnDevicesHTTPStub.nudges.count == 3)
        
        monitor.stop()
        scheduler = ManualNewSignInNudgeScheduler()
        monitor = makeMonitor()
        monitor.start()
        await runRound(at: 480)
        
        #expect(OwnDevicesHTTPStub.nudges.count == 3)
        #expect(NewSignInNudgeMonitor.Environment().history === NewSignInNudgeHistory.shared)
    }
    
    @Test
    func aFailedNudgeDoesNotCountTowardsTheLimits() async throws {
        fixture.devices = [.init(id: phoneID, lastSeen: start, signedBySelfSigningKey: true),
                           .init(id: "WEB", lastSeen: start)]
        let base = try #require(fixture)
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
        #expect(OwnDevicesHTTPStub.nudges.count == 3, "A failed send leaves the cooldown and the limit untouched.")
        
        OwnDevicesHTTPStub.serve(devices: { base.devicesJSON }, keys: { base.keysJSON })
        await runRound(at: 180)
        #expect(OwnDevicesHTTPStub.nudges.count == 4)
        
        await runRound(at: 240)
        #expect(OwnDevicesHTTPStub.nudges.count == 4)
    }
    
    @Test
    func doesNothingWhileThisDeviceIsNotVerified() async {
        verificationState.send(.unverified)
        monitor.start()
        await runRound()
        
        #expect(OwnDevicesHTTPStub.requests.isEmpty)
    }
    
    @Test
    func doesNothingUntilRecoveryHasSettledAsEnabled() async {
        secureBackupController.settledRecoveryStateTimeoutReturnValue = .incomplete
        monitor.start()
        await runRound()
        
        #expect(OwnDevicesHTTPStub.requests.isEmpty)
    }
    
    @Test
    func doesNothingWhileTheSDKDisagreesThatRecoveryIsEnabled() async {
        secureBackupController.sdkRecoveryStateReturnValue = .incomplete
        monitor.start()
        await runRound()
        
        #expect(OwnDevicesHTTPStub.requests.isEmpty)
    }
    
    @Test
    func doesNothingWhileAnIdentityResetIsPending() async {
        IdentityResetPendingStore.markPending(for: userID)
        monitor.start()
        await runRound()
        
        #expect(OwnDevicesHTTPStub.requests.isEmpty)
    }
    
    @Test
    func doesNothingWhileAnIdentityResetIsRunning() async {
        appSettings.setIdentityResetStartedAt(start, forUserID: userID)
        monitor.start()
        await runRound()
        
        #expect(OwnDevicesHTTPStub.requests.isEmpty)
    }
    
    @Test
    func doesNothingWhileSomethingIsPresented() async {
        isIdle = false
        monitor.start()
        await runRound()
        #expect(OwnDevicesHTTPStub.requests.isEmpty)
        
        isIdle = true
        await runRound()
        #expect(OwnDevicesHTTPStub.nudges.count == 1)
    }
    
    @Test
    func doesNotNudgeWhenAModalAppearsWhileReading() async throws {
        let base = try #require(fixture)
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
        
        #expect(OwnDevicesHTTPStub.requests.map(\.method) == ["GET", "POST"])
    }
    
    @Test
    func doesNothingWhileTheAppIsNotActive() async {
        isAppActive = false
        monitor.start()
        await settle()
        #expect(scheduler.liveEntries.map(\.delay) == [.seconds(5)])
        
        scheduler.fire(.seconds(5))
        await monitor.currentRound?.value
        
        #expect(OwnDevicesHTTPStub.requests.isEmpty)
    }
    
    @Test
    func unauthorizedReadSkipsTheRoundAndTheNextRoundReadsAFreshToken() async {
        OwnDevicesHTTPStub.respond { _ in (401, #"{"errcode":"M_UNKNOWN_TOKEN","error":"Token expired"}"#) }
        monitor.start()
        await runRound()
        
        #expect(OwnDevicesHTTPStub.requests.map(\.method) == ["GET"])
        #expect(!clientProxy.logoutCalled)
        
        clientProxy.accessToken = "token-2"
        OwnDevicesHTTPStub.serveFixture()
        await runRound()
        
        let retried = OwnDevicesHTTPStub.requests.dropFirst()
        #expect(retried.map(\.method) == ["GET", "POST", "PUT"])
        #expect(retried.map(\.authorization) == Array(repeating: "Bearer token-2", count: 3))
    }
    
    @Test
    func eachCallReadsAFreshAccessToken() async throws {
        let base = try #require(fixture)
        OwnDevicesHTTPStub.respond { [unowned self] request in
            switch request.method {
            case "GET":
                DispatchQueue.main.sync { self.clientProxy.accessToken = "token-2" }
                return (200, base.devicesJSON)
            case "POST":
                DispatchQueue.main.sync { self.clientProxy.accessToken = "token-3" }
                return (200, base.keysJSON)
            default:
                return (200, "{}")
            }
        }
        monitor.start()
        await runRound()
        
        #expect(OwnDevicesHTTPStub.requests.map(\.authorization) == ["Bearer token-1", "Bearer token-2", "Bearer token-3"])
    }
    
    @Test
    func unauthorizedKeyQuerySendsNoNudge() async {
        let devicesJSON = fixture.devicesJSON
        OwnDevicesHTTPStub.respond { request in
            request.method == "GET" ? (200, devicesJSON) : (401, #"{"errcode":"M_UNKNOWN_TOKEN"}"#)
        }
        monitor.start()
        await runRound()
        
        #expect(OwnDevicesHTTPStub.requests.map(\.method) == ["GET", "POST"])
        #expect(!clientProxy.logoutCalled)
    }
    
    @Test
    func malformedDeviceListSendsNoNudge() async {
        let keysJSON = fixture.keysJSON
        OwnDevicesHTTPStub.serve(devices: { #"{"unexpected": true}"# }, keys: { keysJSON })
        monitor.start()
        await runRound()
        
        #expect(OwnDevicesHTTPStub.requests.map(\.method) == ["GET"])
    }
    
    @Test
    func doesNothingWithoutAnAccessToken() async {
        clientProxy.accessToken = nil
        monitor.start()
        await runRound()
        
        #expect(OwnDevicesHTTPStub.requests.isEmpty)
    }
    
    @Test
    func firstVerificationSchedulesOneRoundFiveSecondsLater() async {
        verificationState.send(.unverified)
        monitor.start()
        await settle()
        #expect(scheduler.liveEntries.filter { $0.delay == .seconds(5) }.isEmpty)
        
        verificationState.send(.verified)
        await settle()
        verificationState.send(.unverified)
        verificationState.send(.verified)
        await settle()
        
        let settled = scheduler.entries.filter { $0.delay == .seconds(5) }
        #expect(settled.count == 1, "Only the first verification in the session schedules a round.")
        #expect(!settled[0].repeats)
        
        scheduler.fire(.seconds(5))
        await monitor.currentRound?.value
        #expect(OwnDevicesHTTPStub.nudges.count == 1)
    }
    
    @Test
    func roundsRepeatEveryMinuteOnlyWhileTheAppIsActive() async {
        monitor.start()
        await settle()
        #expect(scheduler.liveEntries.filter(\.repeats).map(\.delay) == [.seconds(60)])
        
        notificationCenter.post(name: UIApplication.willResignActiveNotification, object: nil)
        #expect(scheduler.liveEntries.isEmpty, "Nothing runs while the app is inactive or in the background.")
        
        notificationCenter.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        let live = scheduler.liveEntries
        #expect(live.filter(\.repeats).map(\.delay) == [.seconds(60)])
        #expect(live.filter { !$0.repeats }.map(\.delay) == [.seconds(5)])
        
        scheduler.fire(.seconds(5))
        await monitor.currentRound?.value
        #expect(OwnDevicesHTTPStub.nudges.count == 1)
    }
    
    @Test
    func doesNotRepeatWhenStartedInTheBackground() {
        isAppActive = false
        monitor.start()
        
        #expect(scheduler.liveEntries.filter(\.repeats).isEmpty)
    }
    
    @Test
    func stopCancelsEverything() async {
        monitor.start()
        await settle()
        #expect(!scheduler.liveEntries.isEmpty)
        
        monitor.stop()
        #expect(scheduler.liveEntries.isEmpty)
        
        notificationCenter.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(scheduler.liveEntries.isEmpty)
    }
    
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
        scheduler.fire(.seconds(60))
        await monitor.currentRound?.value
    }
    
    /// Lets main-queue deliveries (`receive(on:)`) run.
    private func settle() async {
        for _ in 0..<5 {
            await Task.yield()
        }
    }
}
