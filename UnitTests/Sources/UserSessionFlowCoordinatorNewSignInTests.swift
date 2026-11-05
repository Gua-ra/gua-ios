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
final class UserSessionFlowCoordinatorNewSignInTests {
    private let userID = "@alice:gua.test"
    private let phoneID = "PHONE"
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    
    private var rootCoordinator: NavigationRootCoordinator!
    private var flowCoordinator: UserSessionFlowCoordinator!
    private var clientProxy: ClientProxyMock!
    private var verificationController: SessionVerificationControllerProxyMock!
    private var securityState: CurrentValueSubject<SessionSecurityState, Never>!
    private var userIndicatorController: UserIndicatorControllerMock!
    private var ongoingCallRoomID: CurrentValueSubject<String?, Never>!
    private var windowManager: WindowManagerMock!
    private var appSettings: AppSettings!
    private var scheduler: ManualNewSignInNudgeScheduler!
    private var clock: NewSignInNudgeTestClock!
    
    private var tabCoordinator: NavigationTabCoordinator<UserSessionFlowCoordinator.HomeTab>? {
        rootCoordinator.rootCoordinator as? NavigationTabCoordinator
    }
    
    private var chatsSplitCoordinator: NavigationSplitCoordinator? {
        tabCoordinator?.tabCoordinators.first as? NavigationSplitCoordinator
    }
    
    private var spacesSplitCoordinator: NavigationSplitCoordinator? {
        tabCoordinator?.tabCoordinators.compactMap { $0 as? NavigationSplitCoordinator }.last
    }
    
    private var presentedVerificationScreen: SessionVerificationScreenCoordinator? {
        (tabCoordinator?.sheetCoordinator as? NavigationStackCoordinator)?.rootCoordinator as? SessionVerificationScreenCoordinator
    }
    
    init() async throws {
        OwnDevicesHTTPStub.reset()
        IdentityResetPendingStore.clear(for: userID)
        
        let testClock = NewSignInNudgeTestClock(now: start)
        clock = testClock
        scheduler = ManualNewSignInNudgeScheduler()
        clientProxy = ClientProxyMock(.init(homeserver: "https://matrix.gua.test", userID: userID, deviceID: phoneID,
                                            roomSummaryProvider: RoomSummaryProviderMock(.init(state: .loaded(.mockRooms)))))
        clientProxy.accessToken = "token-1"
        clientProxy.verificationStatePublisher = CurrentValueSubject<SessionVerificationState, Never>(.verified).asCurrentValuePublisher()
        let secureBackupController = SecureBackupControllerMock(.init(recoveryState: .enabled))
        secureBackupController.settledRecoveryStateTimeoutReturnValue = .enabled
        secureBackupController.sdkRecoveryStateReturnValue = .enabled
        clientProxy.secureBackupController = secureBackupController
        
        verificationController = SessionVerificationControllerProxyMock.configureMock(requestDelay: .milliseconds(10))
        let verificationActions = verificationController.actions
        verificationController.acceptVerificationRequestClosure = {
            verificationActions.send(.acceptedVerificationRequest)
            return .success(())
        }
        clientProxy.sessionVerificationController = verificationController
        
        let userSession = UserSessionMock(.init(clientProxy: clientProxy, userSettings: .mock(userID: userID)))
        appSettings = userSession.userSettings.app
        // Onboarding would otherwise cover the tab bar for the whole test.
        appSettings.hasRunNotificationPermissionsOnboarding = true
        appSettings.analyticsConsentState = .optedOut
        securityState = .init(.init(verificationState: .verified, recoveryState: .enabled))
        userSession.sessionSecurityStatePublisher = securityState.asCurrentValuePublisher()
        
        userIndicatorController = UserIndicatorControllerMock()
        rootCoordinator = NavigationRootCoordinator()
        
        ongoingCallRoomID = .init(nil)
        let elementCallService = ElementCallServiceMock(.init())
        elementCallService.underlyingOngoingCallRoomIDPublisher = ongoingCallRoomID.asCurrentValuePublisher()
        windowManager = WindowManagerMock()
        let appMediator = AppMediatorMock(.init())
        appMediator.underlyingWindowManager = windowManager
        
        let flowParameters = CommonFlowParameters(userSession: userSession,
                                                  availableSessionsPublisher: .init([.init(userSession: userSession)]),
                                                  bugReportService: BugReportServiceMock(.init()),
                                                  elementCallService: elementCallService,
                                                  timelineControllerFactory: TimelineControllerFactoryMock(.init()),
                                                  emojiProvider: EmojiProvider(userSettings: userSession.userSettings),
                                                  linkMetadataProvider: LinkMetadataProvider(),
                                                  appMediator: appMediator,
                                                  analytics: AnalyticsServiceMock(.init()),
                                                  userIndicatorController: userIndicatorController,
                                                  stateMachineFactory: PublishedStateMachineFactory(),
                                                  spacesSetting: SpacesSetting(clientProxy: clientProxy, appSettings: appSettings))
        
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
        let fixture: @Sendable () -> OwnDevicesFixture = { [userID, phoneID, testClock] in
            OwnDevicesFixture(userID: userID, devices: [
                .init(id: phoneID, lastSeen: testClock.now, signedBySelfSigningKey: true),
                .init(id: "WEB", lastSeen: testClock.now.addingTimeInterval(-30))
            ])
        }
        OwnDevicesHTTPStub.serve(devices: { fixture().devicesJSON }, keys: { fixture().keysJSON })
        
        await settle()
    }
    
    isolated deinit {
        flowCoordinator?.stop()
        OwnDevicesHTTPStub.reset()
    }
    
    @Test
    func subscribesToVerificationRequestsOncePerSession() async throws {
        for recoveryState in [SecureBackupRecoveryState.incomplete, .settingUp, .enabled, .incomplete, .enabled] {
            securityState.send(.init(verificationState: .verified, recoveryState: recoveryState))
        }
        await settle()
        
        verificationController.actions.send(.receivedVerificationRequest(details: requestDetails(from: userID, deviceID: "WEB")))
        try await waitUntil { self.verificationController.acknowledgeVerificationRequestDetailsCallsCount > 0 }
        try await Task.sleep(for: .milliseconds(100))
        
        #expect(verificationController.acknowledgeVerificationRequestDetailsCallsCount == 1)
        guard case .deviceResponder(let details) = presentedVerificationScreen?.viewModel.context.viewState.flow else {
            Issue.record("The request from our own device should be presented to the responder.")
            return
        }
        #expect(details.deviceID == "WEB")
    }
    
    @Test
    func ignoringARequestFromOwnDeviceDismissesThatDevice() async throws {
        verificationController.actions.send(.receivedVerificationRequest(details: requestDetails(from: userID, deviceID: "WEB")))
        let screen = try await presentedScreen()
        
        screen.viewModel.context.send(viewAction: .ignoreVerificationRequest)
        
        #expect(tabCoordinator?.sheetCoordinator == nil)
        #expect(appSettings.dismissedSignInDeviceIDs(forUserID: userID) == ["WEB"])
        
        clock.now = start.addingTimeInterval(600)
        await runRound()
        #expect(OwnDevicesHTTPStub.requests.map(\.method) == ["GET", "POST"], "A dismissed device is never nudged.")
    }
    
    @Test
    func ignoringARequestFromAnotherUserDismissesNothing() async throws {
        verificationController.actions.send(.receivedVerificationRequest(details: requestDetails(from: "@bob:gua.test", deviceID: "BOBPHONE")))
        let screen = try await presentedScreen()
        
        screen.viewModel.context.send(viewAction: .ignoreVerificationRequest)
        
        #expect(tabCoordinator?.sheetCoordinator == nil)
        #expect(appSettings.dismissedSignInDeviceIDs(forUserID: userID) == [])
    }
    
    @Test
    func ownDeviceConfirmationStaysOnScreenUntilDone() async throws {
        verificationController.actions.send(.receivedVerificationRequest(details: requestDetails(from: userID, deviceID: "WEB")))
        let context = try await presentedScreen().viewModel.context
        
        context.send(viewAction: .acceptVerificationRequest)
        try await waitUntil { context.viewState.verificationState == .showingChallenge(emojis: SessionVerificationControllerProxyMock.emojis) }
        context.send(viewAction: .accept)
        try await waitUntil { context.viewState.verificationState == .verified }
        try await Task.sleep(for: .milliseconds(100))
        
        #expect(presentedVerificationScreen != nil, "The confirmation stays on screen until the user taps Done.")
        
        context.send(viewAction: .done)
        #expect(tabCoordinator?.sheetCoordinator == nil)
    }
    
    @Test
    func aRequestFromADeviceHoldsBackItsNudge() async throws {
        verificationController.actions.send(.receivedVerificationRequest(details: requestDetails(from: userID, deviceID: "WEB")))
        _ = try await presentedScreen()
        
        verificationController.actions.send(.cancelled)
        try await waitUntil { self.tabCoordinator?.sheetCoordinator == nil }
        
        await runRound()
        #expect(OwnDevicesHTTPStub.nudges.isEmpty)
        
        clock.now = start.addingTimeInterval(600)
        await runRound()
        #expect(OwnDevicesHTTPStub.nudges.count == 1)
    }
    
    @Test
    func nudgesWhenNothingIsPresented() async {
        #expect(tabCoordinator?.fullScreenCoverCoordinator == nil)
        await runRound()
        
        #expect(OwnDevicesHTTPStub.nudges.count == 1)
    }
    
    @Test
    func doesNotNudgeWhileTheSettingsSheetIsPresented() async {
        flowCoordinator.handleAppRoute(.settings, animated: false)
        await runRound()
        #expect(OwnDevicesHTTPStub.requests.isEmpty)
        
        tabCoordinator?.setSheetCoordinator(nil)
        await runRound()
        #expect(OwnDevicesHTTPStub.nudges.count == 1)
    }
    
    @Test
    func doesNotNudgeWhileAVerificationIsPresented() async throws {
        verificationController.actions.send(.receivedVerificationRequest(details: requestDetails(from: "@bob:gua.test", deviceID: "BOBPHONE")))
        _ = try await presentedScreen()
        
        await runRound()
        #expect(OwnDevicesHTTPStub.requests.isEmpty)
    }
    
    @Test
    func doesNotNudgeWhileASheetIsPresentedInTheChatsTab() async throws {
        let split = try #require(chatsSplitCoordinator)
        split.setSheetCoordinator(PlaceholderScreenCoordinator(hideBrandChrome: false), animated: false)
        await runRound()
        #expect(OwnDevicesHTTPStub.requests.isEmpty)
        
        split.setSheetCoordinator(nil)
        split.setFullScreenCoverCoordinator(PlaceholderScreenCoordinator(hideBrandChrome: false), animated: false)
        await runRound()
        #expect(OwnDevicesHTTPStub.requests.isEmpty)
    }
    
    @Test
    func doesNotNudgeWhileASheetIsPresentedInTheSpacesTab() async throws {
        let split = try #require(spacesSplitCoordinator)
        #expect(split !== chatsSplitCoordinator)
        split.setSheetCoordinator(PlaceholderScreenCoordinator(hideBrandChrome: false), animated: false)
        await runRound()
        #expect(OwnDevicesHTTPStub.requests.isEmpty)
        
        split.setSheetCoordinator(nil)
        split.setFullScreenCoverCoordinator(PlaceholderScreenCoordinator(hideBrandChrome: false), animated: false)
        await runRound()
        #expect(OwnDevicesHTTPStub.requests.isEmpty)
        
        split.setFullScreenCoverCoordinator(nil)
        await runRound()
        #expect(OwnDevicesHTTPStub.nudges.count == 1)
    }
    
    @Test
    func doesNotNudgeDuringACall() async {
        ongoingCallRoomID.send("!call:gua.test")
        await runRound()
        #expect(OwnDevicesHTTPStub.requests.isEmpty)
        
        ongoingCallRoomID.send(nil)
        await runRound()
        #expect(OwnDevicesHTTPStub.nudges.count == 1)
    }
    
    @Test
    func doesNotNudgeWhileTheAppLockScreenIsShown() async {
        let appLockWindow = UIWindow()
        appLockWindow.isHidden = false
        windowManager.alternateWindow = appLockWindow
        await runRound()
        #expect(OwnDevicesHTTPStub.requests.isEmpty)
        
        appLockWindow.isHidden = true
        await runRound()
        #expect(OwnDevicesHTTPStub.nudges.count == 1)
    }
    
    @Test
    func doesNotNudgeWhileAFullScreenCoverOrOverlayIsPresented() async throws {
        let tab = try #require(tabCoordinator)
        tab.setFullScreenCoverCoordinator(PlaceholderScreenCoordinator(hideBrandChrome: false), animated: false)
        await runRound()
        #expect(OwnDevicesHTTPStub.requests.isEmpty)
        
        tab.setFullScreenCoverCoordinator(nil)
        tab.setOverlayCoordinator(PlaceholderScreenCoordinator(hideBrandChrome: false), animated: false)
        await runRound()
        #expect(OwnDevicesHTTPStub.requests.isEmpty)
    }
    
    @Test
    func doesNotNudgeWhileAnAlertIsShown() async {
        rootCoordinator.alertInfo = .init(id: .init(), title: "Alert")
        await runRound()
        #expect(OwnDevicesHTTPStub.requests.isEmpty)
        
        rootCoordinator.alertInfo = nil
        await runRound()
        #expect(OwnDevicesHTTPStub.nudges.count == 1)
    }
    
    @Test
    func stoppingTheFlowStopsTheMonitor() {
        #expect(!scheduler.liveEntries.isEmpty)
        
        flowCoordinator.stop()
        
        #expect(scheduler.liveEntries.isEmpty)
    }
    
    private func requestDetails(from senderID: String, deviceID: String) -> SessionVerificationRequestDetails {
        SessionVerificationRequestDetails(senderProfile: UserProfile(userID: senderID),
                                          flowID: "flow-\(deviceID)",
                                          deviceID: deviceID,
                                          deviceDisplayName: "Gua Web",
                                          firstSeenDate: start)
    }
    
    private func presentedScreen() async throws -> SessionVerificationScreenCoordinator {
        try await waitUntil { self.presentedVerificationScreen != nil }
        return try #require(presentedVerificationScreen)
    }
    
    private func runRound() async {
        scheduler.fire(.seconds(60))
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
                Issue.record("Timed out waiting for the condition.")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
