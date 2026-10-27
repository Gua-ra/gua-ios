//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import XCTest

/// The new sign-in nudge and the verification responder as the session flow drives them.
@MainActor
final class UserSessionFlowCoordinatorNewSignInTests: XCTestCase {
    private let userID = "@alice:gua.test"
    private let phoneID = "PHONE"
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private var rootCoordinator: NavigationRootCoordinator!
    private var flowCoordinator: UserSessionFlowCoordinator!
    private var clientProxy: ClientProxyMock!
    private var verificationController: SessionVerificationControllerProxyMock!
    private var securityState: CurrentValueSubject<SessionSecurityState, Never>!
    private var userIndicatorController: UserIndicatorControllerMock!
    private var appSettings: AppSettings!
    private var scheduler: ManualNewSignInNudgeScheduler!
    private var clock: NewSignInNudgeTestClock!
    private var savedOnboardingSettings: (notifications: Bool, analytics: AnalyticsConsentState)?

    private var tabCoordinator: NavigationTabCoordinator<UserSessionFlowCoordinator.HomeTab>? {
        rootCoordinator.rootCoordinator as? NavigationTabCoordinator
    }

    private var chatsSplitCoordinator: NavigationSplitCoordinator? {
        tabCoordinator?.tabCoordinators.first as? NavigationSplitCoordinator
    }

    private var presentedVerificationScreen: SessionVerificationScreenCoordinator? {
        (tabCoordinator?.sheetCoordinator as? NavigationStackCoordinator)?.rootCoordinator as? SessionVerificationScreenCoordinator
    }

    override func setUp() async throws {
        OwnDevicesHTTPStub.reset()
        AppSettings.resetSessionSpecificSettings()
        IdentityResetPendingStore.clear(for: userID)

        let testClock = NewSignInNudgeTestClock(now: start)
        clock = testClock
        scheduler = ManualNewSignInNudgeScheduler()
        appSettings = ServiceLocator.shared.settings
        // Onboarding would otherwise cover the tab bar for the whole test.
        savedOnboardingSettings = (appSettings.hasRunNotificationPermissionsOnboarding, appSettings.analyticsConsentState)
        appSettings.hasRunNotificationPermissionsOnboarding = true
        appSettings.analyticsConsentState = .optedOut

        clientProxy = ClientProxyMock(.init(homeserver: "https://matrix.gua.test", userID: userID, deviceID: phoneID,
                                            roomSummaryProvider: RoomSummaryProviderMock(.init(state: .loaded(.mockRooms)))))
        clientProxy.accessToken = "token-1"
        clientProxy.verificationStatePublisher = CurrentValueSubject<SessionVerificationState, Never>(.verified).asCurrentValuePublisher()
        let secureBackupController = SecureBackupControllerMock(.init(recoveryState: .enabled))
        secureBackupController.settledRecoveryStateTimeoutReturnValue = .enabled
        secureBackupController.sdkRecoveryStateReturnValue = .enabled
        clientProxy.secureBackupController = secureBackupController

        verificationController = SessionVerificationControllerProxyMock.configureMock(requestDelay: .milliseconds(10))
        verificationController.acceptVerificationRequestReturnValue = .success(())
        clientProxy.sessionVerificationController = verificationController

        let userSession = UserSessionMock(.init(clientProxy: clientProxy))
        securityState = .init(.init(verificationState: .verified, recoveryState: .enabled))
        userSession.sessionSecurityStatePublisher = securityState.asCurrentValuePublisher()

        userIndicatorController = UserIndicatorControllerMock()
        rootCoordinator = NavigationRootCoordinator()

        let flowParameters = CommonFlowParameters(userSession: userSession,
                                                  bugReportService: BugReportServiceMock(.init()),
                                                  elementCallService: ElementCallServiceMock(.init()),
                                                  timelineControllerFactory: TimelineControllerFactoryMock(.init()),
                                                  emojiProvider: EmojiProvider(appSettings: appSettings),
                                                  linkMetadataProvider: LinkMetadataProvider(),
                                                  appMediator: AppMediatorMock.default,
                                                  appSettings: appSettings,
                                                  appHooks: AppHooks(),
                                                  analytics: ServiceLocator.shared.analytics,
                                                  userIndicatorController: userIndicatorController,
                                                  notificationManager: NotificationManagerMock(),
                                                  stateMachineFactory: PublishedStateMachineFactory())

        flowCoordinator = UserSessionFlowCoordinator(isNewLogin: false,
                                                     navigationRootCoordinator: rootCoordinator,
                                                     appLockService: AppLockServiceMock(),
                                                     flowParameters: flowParameters,
                                                     newSignInNudgeEnvironment: .init(urlSession: OwnDevicesHTTPStub.makeSession(),
                                                                                      notificationCenter: NotificationCenter(),
                                                                                      scheduler: scheduler,
                                                                                      now: { [unowned self] in clock.now },
                                                                                      history: NewSignInNudgeHistory()))
        flowCoordinator.start()

        // The web device stays recently seen however far a test moves the clock.
        let fixture = { [userID, phoneID, testClock] in
            OwnDevicesFixture(userID: userID, devices: [
                .init(id: phoneID, lastSeen: testClock.now, signedBySelfSigningKey: true),
                .init(id: "WEB", lastSeen: testClock.now.addingTimeInterval(-30))
            ])
        }
        OwnDevicesHTTPStub.serve(devices: { fixture().devicesJSON }, keys: { fixture().keysJSON })

        await settle()
    }

    override func tearDown() async throws {
        flowCoordinator?.stop()
        if let savedOnboardingSettings {
            appSettings.hasRunNotificationPermissionsOnboarding = savedOnboardingSettings.notifications
            appSettings.analyticsConsentState = savedOnboardingSettings.analytics
        }
        AppSettings.resetSessionSpecificSettings()
        OwnDevicesHTTPStub.reset()
    }

    // MARK: - Responder

    func testSubscribesToVerificationRequestsOncePerSession() async throws {
        for recoveryState in [SecureBackupRecoveryState.incomplete, .settingUp, .enabled, .incomplete, .enabled] {
            securityState.send(.init(verificationState: .verified, recoveryState: recoveryState))
        }
        await settle()

        verificationController.actions.send(.receivedVerificationRequest(details: requestDetails(from: userID, deviceID: "WEB")))
        try await waitUntil { self.verificationController.acknowledgeVerificationRequestDetailsCallsCount > 0 }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(verificationController.acknowledgeVerificationRequestDetailsCallsCount, 1)
        guard case .deviceResponder(let details) = presentedVerificationScreen?.viewModel.context.viewState.flow else {
            return XCTFail("The request from our own device should be presented to the responder.")
        }
        XCTAssertEqual(details.deviceID, "WEB")
    }

    func testIgnoringARequestFromOwnDeviceDismissesThatDevice() async throws {
        verificationController.actions.send(.receivedVerificationRequest(details: requestDetails(from: userID, deviceID: "WEB")))
        let screen = try await presentedScreen()

        // What the Ignore button sends.
        screen.viewModel.context.send(viewAction: .ignoreVerificationRequest)

        XCTAssertNil(tabCoordinator?.sheetCoordinator)
        XCTAssertEqual(appSettings.dismissedSignInDeviceIDs(forUserID: userID), ["WEB"])

        clock.now = start.addingTimeInterval(NewSignInNudgeMonitor.recentRequestWindow)
        await runRound()
        XCTAssertEqual(OwnDevicesHTTPStub.requests.map(\.method), ["GET", "POST"], "A dismissed device is never nudged.")
    }

    func testIgnoringARequestFromAnotherUserDismissesNothing() async throws {
        verificationController.actions.send(.receivedVerificationRequest(details: requestDetails(from: "@bob:gua.test", deviceID: "BOBPHONE")))
        let screen = try await presentedScreen()

        screen.viewModel.context.send(viewAction: .ignoreVerificationRequest)

        XCTAssertNil(tabCoordinator?.sheetCoordinator)
        XCTAssertEqual(appSettings.dismissedSignInDeviceIDs(forUserID: userID), [])
    }

    func testARequestFromADeviceHoldsBackItsNudge() async throws {
        verificationController.actions.send(.receivedVerificationRequest(details: requestDetails(from: userID, deviceID: "WEB")))
        _ = try await presentedScreen()

        // The other side cancels; the responder sheet closes on its own.
        verificationController.actions.send(.cancelled)
        try await waitUntil { self.tabCoordinator?.sheetCoordinator == nil }

        await runRound()
        XCTAssertTrue(OwnDevicesHTTPStub.nudges.isEmpty)

        clock.now = start.addingTimeInterval(NewSignInNudgeMonitor.recentRequestWindow)
        await runRound()
        XCTAssertEqual(OwnDevicesHTTPStub.nudges.count, 1)
    }

    // MARK: - Gate

    func testNudgesWhenNothingIsPresented() async {
        XCTAssertNil(tabCoordinator?.fullScreenCoverCoordinator)
        await runRound()

        XCTAssertEqual(OwnDevicesHTTPStub.nudges.count, 1)
    }

    func testDoesNotNudgeWhileTheSettingsSheetIsPresented() async {
        flowCoordinator.handleAppRoute(.settings, animated: false)
        await runRound()
        XCTAssertTrue(OwnDevicesHTTPStub.requests.isEmpty)

        tabCoordinator?.setSheetCoordinator(nil)
        await runRound()
        XCTAssertEqual(OwnDevicesHTTPStub.nudges.count, 1)
    }

    func testDoesNotNudgeWhileAVerificationIsPresented() async throws {
        verificationController.actions.send(.receivedVerificationRequest(details: requestDetails(from: "@bob:gua.test", deviceID: "BOBPHONE")))
        _ = try await presentedScreen()

        await runRound()
        XCTAssertTrue(OwnDevicesHTTPStub.requests.isEmpty)
    }

    func testDoesNotNudgeWhileASheetIsPresentedInTheChatsTab() async throws {
        let split = try XCTUnwrap(chatsSplitCoordinator)
        split.setSheetCoordinator(PlaceholderScreenCoordinator(), animated: false)
        await runRound()
        XCTAssertTrue(OwnDevicesHTTPStub.requests.isEmpty)

        split.setSheetCoordinator(nil)
        split.setFullScreenCoverCoordinator(PlaceholderScreenCoordinator(), animated: false)
        await runRound()
        XCTAssertTrue(OwnDevicesHTTPStub.requests.isEmpty)
    }

    func testDoesNotNudgeWhileAFullScreenCoverOrOverlayIsPresented() async throws {
        let tab = try XCTUnwrap(tabCoordinator)
        tab.setFullScreenCoverCoordinator(PlaceholderScreenCoordinator(), animated: false)
        await runRound()
        XCTAssertTrue(OwnDevicesHTTPStub.requests.isEmpty)

        tab.setFullScreenCoverCoordinator(nil)
        tab.setOverlayCoordinator(PlaceholderScreenCoordinator(), animated: false)
        await runRound()
        XCTAssertTrue(OwnDevicesHTTPStub.requests.isEmpty)
    }

    func testDoesNotNudgeWhileAnAlertIsShown() async {
        userIndicatorController.alertInfo = .init(id: .init(), title: "Alert")
        await runRound()
        XCTAssertTrue(OwnDevicesHTTPStub.requests.isEmpty)

        userIndicatorController.alertInfo = nil
        await runRound()
        XCTAssertEqual(OwnDevicesHTTPStub.nudges.count, 1)
    }

    func testStoppingTheFlowStopsTheMonitor() {
        XCTAssertFalse(scheduler.liveEntries.isEmpty)

        flowCoordinator.stop()

        XCTAssertTrue(scheduler.liveEntries.isEmpty)
    }

    // MARK: - Helpers

    private func requestDetails(from senderID: String, deviceID: String) -> SessionVerificationRequestDetails {
        SessionVerificationRequestDetails(senderProfile: UserProfileProxy(userID: senderID),
                                          flowID: "flow-\(deviceID)",
                                          deviceID: deviceID,
                                          deviceDisplayName: "Gua Web",
                                          firstSeenDate: start)
    }

    private func presentedScreen() async throws -> SessionVerificationScreenCoordinator {
        try await waitUntil { self.presentedVerificationScreen != nil }
        return try XCTUnwrap(presentedVerificationScreen)
    }

    private func runRound() async {
        scheduler.fire(NewSignInNudgeMonitor.roundInterval)
        await flowCoordinator.newSignInNudgeMonitor?.currentRound?.value
    }

    private func settle() async {
        for _ in 0..<5 {
            await Task.yield()
        }
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: @escaping () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                return XCTFail("Timed out waiting for the condition.")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
