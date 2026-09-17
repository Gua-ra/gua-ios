//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import XCTest

@MainActor
class HomeScreenViewModelTests: XCTestCase {
    var viewModel: HomeScreenViewModelProtocol!
    var context: HomeScreenViewModelType.Context! {
        viewModel.context
    }
    
    var clientProxy: ClientProxyMock!
    var roomSummaryProvider: RoomSummaryProviderMock!
    var appSettings: AppSettings!
    var notificationManager: NotificationManagerMock!
    private var identityService: HomeScreenIdentityServiceStub!
    private var notificationCenter: NotificationCenter!
    private var userIndicatorController: UserIndicatorControllerMock!
    
    var cancellables = Set<AnyCancellable>()
    
    override func setUp() {
        cancellables.removeAll()
        
        AppSettings.resetAllSettings()
        appSettings = AppSettings()
        ServiceLocator.shared.register(appSettings: appSettings)
    }
    
    override func tearDown() {
        AppSettings.resetAllSettings()
    }
    
    func testSelectRoom() async {
        setupViewModel()
        
        let mockRoomID = "mock_room_id"
        var correctResult = false
        var selectedRoomID = ""
        
        viewModel.actions
            .sink { action in
                switch action {
                case .presentRoom(let roomID):
                    correctResult = true
                    selectedRoomID = roomID
                default:
                    break
                }
            }
            .store(in: &cancellables)
        
        context.send(viewAction: .selectRoom(roomIdentifier: mockRoomID))
        await Task.yield()
        XCTAssert(correctResult)
        XCTAssertEqual(mockRoomID, selectedRoomID)
    }

    func testTapUserAvatar() async {
        setupViewModel()
        
        var correctResult = false
        
        viewModel.actions
            .sink { action in
                switch action {
                case .presentSettingsScreen:
                    correctResult = true
                default:
                    break
                }
            }
            .store(in: &cancellables)
        
        context.send(viewAction: .showSettings)
        await Task.yield()
        XCTAssert(correctResult)
    }
    
    func testLeaveRoomAlert() async throws {
        setupViewModel()
        
        let mockRoomID = "1"
        
        clientProxy.roomForIdentifierClosure = { _ in .joined(JoinedRoomProxyMock(.init(id: mockRoomID, name: "Some room"))) }
        
        let deferred = deferFulfillment(context.$viewState) { value in
            value.bindings.leaveRoomAlertItem != nil
        }
        
        context.send(viewAction: .leaveRoom(roomIdentifier: mockRoomID))
        
        try await deferred.fulfill()
        
        XCTAssertEqual(context.leaveRoomAlertItem?.roomID, mockRoomID)
    }
    
    func testLeaveRoomError() async throws {
        setupViewModel()
        
        let mockRoomID = "1"
        let room = JoinedRoomProxyMock(.init(id: mockRoomID, name: "Some room"))
        room.leaveRoomClosure = { .failure(.sdkError(ClientProxyMockError.generic)) }
        
        clientProxy.roomForIdentifierClosure = { _ in .joined(room) }

        let deferred = deferFulfillment(context.$viewState) { value in
            value.bindings.alertInfo != nil
        }
        
        context.send(viewAction: .confirmLeaveRoom(roomIdentifier: mockRoomID))
        
        try await deferred.fulfill()
                
        XCTAssertNotNil(context.alertInfo)
    }
    
    func testLeaveRoomSuccess() async {
        setupViewModel()
        
        let mockRoomID = "1"
        var correctResult = false
        let expectation = expectation(description: #function)
        viewModel.actions
            .sink { action in
                switch action {
                case .roomLeft(let roomIdentifier):
                    correctResult = roomIdentifier == mockRoomID
                default:
                    break
                }
                expectation.fulfill()
            }
            .store(in: &cancellables)
        let room = JoinedRoomProxyMock(.init(id: mockRoomID, name: "Some room"))
        room.leaveRoomClosure = { .success(()) }
        
        clientProxy.roomForIdentifierClosure = { _ in .joined(room) }
        
        context.send(viewAction: .confirmLeaveRoom(roomIdentifier: mockRoomID))
        await fulfillment(of: [expectation])
        XCTAssertNil(context.alertInfo)
        XCTAssertTrue(correctResult)
    }
    
    func testShowRoomDetails() async {
        setupViewModel()
        
        let mockRoomID = "1"
        var correctResult = false
        viewModel.actions
            .sink { action in
                switch action {
                case .presentRoomDetails(let roomIdentifier):
                    correctResult = roomIdentifier == mockRoomID
                default:
                    break
                }
            }
            .store(in: &cancellables)
        context.send(viewAction: .showRoomDetails(roomIdentifier: mockRoomID))
        await Task.yield()
        XCTAssertNil(context.alertInfo)
        XCTAssertTrue(correctResult)
    }
    
    func testFilters() async throws {
        setupViewModel()
        
        context.filtersState.activateFilter(.people)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(roomSummaryProvider.roomListPublisher.value.count, 2)
        XCTAssertEqual(roomSummaryProvider.roomListPublisher.value.first?.name, "Foundation and Earth")
    }
    
    func testSearch() async throws {
        setupViewModel()
        
        context.isSearchFieldFocused = true
        context.searchQuery = "lude to Found"
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(roomSummaryProvider.roomListPublisher.value.first?.name, "Prelude to Foundation")
        XCTAssertEqual(roomSummaryProvider.roomListPublisher.value.count, 1)
    }
    
    func testFiltersEmptyState() async throws {
        setupViewModel()
        
        context.filtersState.activateFilter(.people)
        context.filtersState.activateFilter(.favourites)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(context.viewState.shouldShowEmptyFilterState)
        context.isSearchFieldFocused = true
        XCTAssertFalse(context.viewState.shouldShowEmptyFilterState)
    }
    
    func testSetUpRecoveryBannerState() async throws {
        // Given a view model without a visible security banner.
        let securityStateStateSubject = CurrentValueSubject<SessionSecurityState, Never>(.init(verificationState: .verified, recoveryState: .unknown))
        setupViewModel(securityStatePublisher: securityStateStateSubject.asCurrentValuePublisher())
        XCTAssertEqual(context.viewState.securityBannerMode, .none)
        
        // When the recovery state comes through as disabled.
        var deferred = deferFulfillment(context.$viewState) { $0.requiresExtraAccountSetup == true }
        securityStateStateSubject.send(.init(verificationState: .verified, recoveryState: .disabled))
        try await deferred.fulfill()
        
        // Then the banner should be the one that finishes setup silently. GUA FORK: .disabled
        // used to show .setUpRecovery, whose flow hands the user a recovery key to write down,
        // and .disabled is the state an identity reset leaves behind.
        XCTAssertEqual(context.viewState.securityBannerMode, .show(.recoveryOutOfSync))
        
        // When the recovery is enabled.
        deferred = deferFulfillment(context.$viewState) { $0.requiresExtraAccountSetup == false }
        securityStateStateSubject.send(.init(verificationState: .verified, recoveryState: .enabled))
        try await deferred.fulfill()
        
        // Then the banner should no longer be shown.
        XCTAssertEqual(context.viewState.securityBannerMode, .none)
    }
    
    func testTheBannerButtonRoutesToTheStagedRepair() {
        // The banner is the ONLY encryption affordance a user has, so its button must go to the
        // staged repair. If it points at .resetEncryption again, every tap skips straight to
        // "Some previous messages can't be recovered" and the silent path becomes dead code.
        XCTAssertEqual(HomeScreenRecoveryKeyConfirmationBanner.State.recoveryOutOfSync.primaryAction,
                       .confirmRecoveryKey)
    }

    func testFinishSetupRepairsWithoutAskingToReset() async throws {
        // Given a device whose key storage can still be repaired without discarding the backup.
        setupViewModel()
        let secureBackupController = try XCTUnwrap(clientProxy.secureBackupController as? SecureBackupControllerMock)
        secureBackupController.repairWithoutResetReturnValue = .repaired

        var receivedAction: HomeScreenViewModelAction?
        viewModel.actions.sink { receivedAction = $0 }.store(in: &cancellables)

        // When the user taps the banner's button. Drive it through the banner's own primaryAction
        // rather than naming the action: sending .confirmRecoveryKey directly is what let the
        // banner sit on .resetEncryption for a whole release with these tests green.
        context.send(viewAction: HomeScreenRecoveryKeyConfirmationBanner.State.recoveryOutOfSync.primaryAction)
        try await Task.sleep(for: .milliseconds(200))

        // Then it repairs silently and never offers the destructive reset.
        XCTAssertEqual(secureBackupController.repairWithoutResetCallsCount, 1)
        XCTAssertNil(receivedAction)
    }

    func testFinishSetupAsksBeforeResettingWhenRepairIsImpossible() async throws {
        // Given a device that cannot be finished without discarding the backup.
        setupViewModel()
        let secureBackupController = try XCTUnwrap(clientProxy.secureBackupController as? SecureBackupControllerMock)
        secureBackupController.repairWithoutResetReturnValue = .resetRequired

        var receivedAction: HomeScreenViewModelAction?
        viewModel.actions.sink { receivedAction = $0 }.store(in: &cancellables)

        // When the user taps the banner's button, via the banner's own primaryAction.
        context.send(viewAction: HomeScreenRecoveryKeyConfirmationBanner.State.recoveryOutOfSync.primaryAction)
        try await Task.sleep(for: .milliseconds(200))

        // Then the reset is disclosed rather than performed silently.
        XCTAssertEqual(secureBackupController.repairWithoutResetCallsCount, 1)
        XCTAssertEqual(receivedAction, .presentEncryptionResetScreen)
    }

    func testDismissSetUpRecoveryBannerState() async throws {
        // Given a view model with the setup recovery banner shown.
        let securityStateStateSubject = CurrentValueSubject<SessionSecurityState, Never>(.init(verificationState: .verified, recoveryState: .unknown))
        setupViewModel(securityStatePublisher: securityStateStateSubject.asCurrentValuePublisher())
        var deferred = deferFulfillment(context.$viewState) { $0.securityBannerMode == .show(.recoveryOutOfSync) }
        securityStateStateSubject.send(.init(verificationState: .verified, recoveryState: .disabled))
        try await deferred.fulfill()
        
        // When the banner is dismissed.
        deferred = deferFulfillment(context.$viewState) { $0.securityBannerMode == .dismissed }
        context.send(viewAction: .skipRecoveryKeyConfirmation)
        
        // Then the banner should no longer be shown.
        try await deferred.fulfill()
        
        // And when the recovery state comes through a second time the banner should still not be shown.
        let failure = deferFailure(context.$viewState, timeout: 1) { $0.securityBannerMode != .dismissed }
        securityStateStateSubject.send(.init(verificationState: .verified, recoveryState: .disabled))
        try await failure.fulfill()
    }
    
    func testOutOfSyncRecoveryBannerState() async throws {
        // Given a view model without a visible security banner.
        let securityStateStateSubject = CurrentValueSubject<SessionSecurityState, Never>(.init(verificationState: .verified, recoveryState: .unknown))
        setupViewModel(securityStatePublisher: securityStateStateSubject.asCurrentValuePublisher())
        XCTAssertEqual(context.viewState.securityBannerMode, .none)
        
        // When the recovery state comes through as incomplete.
        var deferred = deferFulfillment(context.$viewState) { $0.requiresExtraAccountSetup == true }
        securityStateStateSubject.send(.init(verificationState: .verified, recoveryState: .incomplete))
        try await deferred.fulfill()
        
        // Then the banner should be shown for out of sync recovery.
        XCTAssertEqual(context.viewState.securityBannerMode, .show(.recoveryOutOfSync))
        
        // When the recovery is enabled.
        deferred = deferFulfillment(context.$viewState) { $0.requiresExtraAccountSetup == false }
        securityStateStateSubject.send(.init(verificationState: .verified, recoveryState: .enabled))
        try await deferred.fulfill()
        
        // Then the banner should no longer be shown.
        XCTAssertEqual(context.viewState.securityBannerMode, .none)
    }
    
    func testInviteUnreadBadge() async throws {
        setupViewModel(withInvites: true)
        var invites = context.viewState.rooms.invites
        XCTAssertEqual(invites.count, 2)
        
        for invite in invites {
            XCTAssertTrue(invite.badges.isDotShown)
        }
        
        let deferred = deferFulfillment(context.$viewState) { state in
            state.rooms.contains { room in
                room.roomID == invites[0].roomID && room.badges.isDotShown == false
            }
        }
        appSettings.seenInvites = Set(invites.compactMap(\.roomID))
        try await deferred.fulfill()
        invites = context.viewState.rooms.invites
        
        for invite in invites {
            XCTAssertFalse(invite.badges.isDotShown)
        }
    }
    
    func testAcceptInvite() async throws {
        setupViewModel(withInvites: true)
        
        let invitedRoomIDs = context.viewState.rooms.invites.compactMap(\.roomID)
        appSettings.seenInvites = Set(invitedRoomIDs)
        XCTAssertEqual(invitedRoomIDs.count, 2)
        
        let deferred = deferFulfillment(viewModel.actions) { $0 == .presentRoom(roomIdentifier: invitedRoomIDs[0]) }
        context.send(viewAction: .acceptInvite(roomIdentifier: invitedRoomIDs[0]))
        try await deferred.fulfill()
        
        XCTAssertEqual(appSettings.seenInvites, [invitedRoomIDs[1]])
        XCTAssertFalse(notificationManager.removeDeliveredMessageNotificationsForCalled, "The notification will be dismissed when opening the room.")
    }
    
    func testDeclineInvite() async throws {
        setupViewModel(withInvites: true)
        let invitedRoomIDs = context.viewState.rooms.invites.compactMap(\.roomID)
        appSettings.seenInvites = Set(invitedRoomIDs)
        XCTAssertEqual(invitedRoomIDs.count, 2)
        
        let deferred = deferFulfillment(context.$viewState) { $0.bindings.alertInfo != nil }
        context.send(viewAction: .declineInvite(roomIdentifier: invitedRoomIDs[0]))
        try await deferred.fulfill()
        
        let rejectExpectation = expectation(description: "Expected rejectInvitation to be called.")
        let notificationExpectation = expectation(description: "Expected delivered notifications to be removed.")
        notificationManager.removeDeliveredMessageNotificationsForClosure = { roomID in
            XCTAssertEqual(roomID, invitedRoomIDs[0])
            notificationExpectation.fulfill()
        }
        clientProxy.roomForIdentifierClosure = { _ in
            let roomProxy = InvitedRoomProxyMock(.init())
            roomProxy.rejectInvitationClosure = {
                rejectExpectation.fulfill()
                return .success(())
            }
            
            return .invited(roomProxy)
        }
        context.viewState.bindings.alertInfo?.verticalButtons?[0].action?()
        await fulfillment(of: [rejectExpectation, notificationExpectation], timeout: 1.0)
        
        XCTAssertEqual(appSettings.seenInvites, [invitedRoomIDs[1]])
        XCTAssertTrue(notificationManager.removeDeliveredMessageNotificationsForCalled)
        XCTAssertEqual(notificationManager.removeDeliveredMessageNotificationsForReceivedInvocations, [invitedRoomIDs[0]])
    }
    
    func testDeclineAndBlockInvite() async throws {
        setupViewModel(withInvites: true)
        let invitedRoomIDs = context.viewState.rooms.invites.compactMap(\.roomID)
        appSettings.seenInvites = Set(invitedRoomIDs)
        XCTAssertEqual(invitedRoomIDs.count, 2)
        
        let deferred = deferFulfillment(context.$viewState) { $0.bindings.alertInfo != nil }
        context.send(viewAction: .declineInvite(roomIdentifier: invitedRoomIDs[0]))
        try await deferred.fulfill()
        
        let deferredAction = deferFulfillment(viewModel.actions) { $0 == .presentDeclineAndBlock(userID: RoomMemberProxyMock.mockCharlie.userID, roomID: invitedRoomIDs[0]) }
        context.viewState.bindings.alertInfo?.secondaryButton?.action?()
        try await deferredAction.fulfill()
    }
    
    // MARK: - Account recovery banner
    
    func testAccountRecoveryBannerShowsWhilePendingEvenWhenThePinReminderIsSnoozed() async throws {
        // Given an account with no factor and a live recovery, and a PIN reminder the user snoozed.
        appSettings.pinSetupReminderSnoozedUntil = Date().addingTimeInterval(24 * 60 * 60)
        let recovery = PendingAccountRecovery(completableAt: Date(timeIntervalSince1970: 2_000_000_000),
                                              expiresAt: Date(timeIntervalSince1970: 2_000_600_000))
        
        // When the home screen reads the report at session start.
        setupViewModel(identityServiceStatus: Self.status(pendingAccountRecovery: recovery))
        try await deferFulfillment(context.$viewState) { $0.accountRecoveryBanner != nil }.fulfill()
        
        // Then the recovery banner is up and the snooze only kept the nudge away.
        XCTAssertEqual(context.viewState.accountRecoveryBanner, recovery)
        XCTAssertFalse(context.viewState.pinSetupReminderVisible)
    }
    
    func testNoAccountRecoveryBannerWhenNothingIsPending() async throws {
        // Given an account with no factor and nothing pending.
        setupViewModel(identityServiceStatus: Self.status(pendingAccountRecovery: nil))
        try await deferFulfillment(context.$viewState) { $0.pinSetupReminderVisible }.fulfill()
        
        // Then only the nudge shows.
        XCTAssertNil(context.viewState.accountRecoveryBanner)
    }
    
    func testForegroundRefetchesTheAccountRecoveryStatus() async throws {
        // Given a home screen that read a report with nothing pending.
        setupViewModel(identityServiceStatus: Self.status(pendingAccountRecovery: nil))
        try await waitUntil { self.identityService.securityStatusCalls == 1 }
        XCTAssertNil(context.viewState.accountRecoveryBanner)
        
        // When someone starts a recovery while the app is in the background and it comes back.
        let recovery = PendingAccountRecovery(completableAt: nil, expiresAt: nil)
        identityService.status = Self.status(pendingAccountRecovery: recovery)
        let deferred = deferFulfillment(context.$viewState) { $0.accountRecoveryBanner != nil }
        notificationCenter.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await deferred.fulfill()
        
        // Then the report is read again and the banner appears.
        XCTAssertEqual(identityService.securityStatusCalls, 2)
        XCTAssertEqual(context.viewState.accountRecoveryBanner, recovery)
    }
    
    func testAFailedRefetchKeepsTheAccountRecoveryBanner() async throws {
        // Given a banner for a live recovery.
        let recovery = PendingAccountRecovery(completableAt: nil, expiresAt: nil)
        setupViewModel(identityServiceStatus: Self.status(pendingAccountRecovery: recovery))
        try await deferFulfillment(context.$viewState) { $0.accountRecoveryBanner != nil }.fulfill()
        
        // When the report cannot be read on the next foreground.
        identityService.status = nil
        notificationCenter.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await waitUntil { self.identityService.securityStatusCalls == 2 }
        
        // Then the banner stays: a bad network is no reason to hide it.
        XCTAssertEqual(context.viewState.accountRecoveryBanner, recovery)
    }
    
    func testCancelAccountRecoveryAsksFirstThenCancelsRefetchesAndConfirms() async throws {
        // Given a banner for a live recovery.
        setupViewModel(identityServiceStatus: Self.status(pendingAccountRecovery: PendingAccountRecovery(completableAt: nil, expiresAt: nil)))
        try await deferFulfillment(context.$viewState) { $0.accountRecoveryBanner != nil }.fulfill()
        
        // When the owner taps Cancel recovery.
        let alertShown = deferFulfillment(context.$viewState) { $0.bindings.alertInfo != nil }
        context.send(viewAction: .cancelAccountRecovery)
        try await alertShown.fulfill()
        
        // Then nothing is cancelled until they confirm.
        XCTAssertEqual(context.alertInfo?.title, L10n.screenAccountRecoveryCancelConfirmTitle)
        XCTAssertEqual(identityService.cancelCalls, 0)
        
        // When they confirm.
        let callsBeforeCancel = identityService.securityStatusCalls
        let bannerGone = deferFulfillment(context.$viewState) { $0.accountRecoveryBanner == nil }
        context.alertInfo?.secondaryButton?.action?()
        try await bannerGone.fulfill()
        try await waitUntil { self.userIndicatorController.submitIndicatorDelayReceivedArguments?.indicator.title == L10n.screenAccountRecoveryCancelled }
        
        // Then the server is asked once, the report is read again, and the owner is told.
        XCTAssertEqual(identityService.cancelCalls, 1)
        XCTAssertEqual(identityService.securityStatusCalls, callsBeforeCancel + 1)
        XCTAssertNil(context.viewState.accountRecoveryBanner)
    }
    
    func testAStatusReadThatStartedBeforeACancelDoesNotBringTheBannerBack() async throws {
        // Given a banner for a live recovery, and a foreground read that is still waiting on a slow network.
        setupViewModel(identityServiceStatus: Self.status(pendingAccountRecovery: PendingAccountRecovery(completableAt: nil, expiresAt: nil)))
        try await deferFulfillment(context.$viewState) { $0.accountRecoveryBanner != nil }.fulfill()
        identityService.holdsStatusReads = true
        notificationCenter.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await waitUntil { self.identityService.securityStatusCalls == 2 }
        identityService.holdsStatusReads = false
        
        // When the owner cancels before that read comes back.
        let alertShown = deferFulfillment(context.$viewState) { $0.bindings.alertInfo != nil }
        context.send(viewAction: .cancelAccountRecovery)
        try await alertShown.fulfill()
        context.alertInfo?.secondaryButton?.action?()
        try await waitUntil { self.userIndicatorController.submitIndicatorDelayReceivedArguments?.indicator.title == L10n.screenAccountRecoveryCancelled }
        XCTAssertNil(context.viewState.accountRecoveryBanner)
        
        // And the old read, which still saw the recovery as pending, finally returns.
        identityService.releaseHeldStatusReads()
        try await waitUntil { self.identityService.securityStatusReturns == 3 }
        try await Task.sleep(for: .milliseconds(100))
        
        // Then it describes the account as it was before the cancel and is ignored.
        XCTAssertEqual(identityService.cancelCalls, 1)
        XCTAssertNil(context.viewState.accountRecoveryBanner)
    }
    
    func testCancelThatLeavesTheRecoveryLiveKeepsTheBannerAndSaysSo() async throws {
        // Given a banner for a live recovery, and a server that accepts the cancel but still reports it live.
        let recovery = PendingAccountRecovery(completableAt: nil, expiresAt: nil)
        setupViewModel(identityServiceStatus: Self.status(pendingAccountRecovery: recovery))
        identityService.cancelClearsRecovery = false
        try await deferFulfillment(context.$viewState) { $0.accountRecoveryBanner != nil }.fulfill()
        
        let alertShown = deferFulfillment(context.$viewState) { $0.bindings.alertInfo != nil }
        context.send(viewAction: .cancelAccountRecovery)
        try await alertShown.fulfill()
        
        // When the owner confirms.
        let callsBeforeCancel = identityService.securityStatusCalls
        let errorShown = deferFulfillment(context.$viewState) { $0.bindings.alertInfo?.message == L10n.screenAccountRecoveryCancelFailed }
        context.alertInfo?.secondaryButton?.action?()
        try await errorShown.fulfill()
        
        // Then the fresh read puts the banner back and no toast claims the recovery was cancelled.
        XCTAssertEqual(identityService.cancelCalls, 1)
        XCTAssertEqual(identityService.securityStatusCalls, callsBeforeCancel + 1)
        XCTAssertEqual(context.viewState.accountRecoveryBanner, recovery)
        XCTAssertNotEqual(userIndicatorController.submitIndicatorDelayReceivedArguments?.indicator.title, L10n.screenAccountRecoveryCancelled)
    }
    
    func testCancelAccountRecoveryFailureKeepsTheBannerAndSaysSo() async throws {
        // Given a banner for a live recovery and a server that refuses the cancel.
        let recovery = PendingAccountRecovery(completableAt: nil, expiresAt: nil)
        setupViewModel(identityServiceStatus: Self.status(pendingAccountRecovery: recovery))
        identityService.cancelError = IdentityServiceError.server(status: 500, message: nil)
        try await deferFulfillment(context.$viewState) { $0.accountRecoveryBanner != nil }.fulfill()
        
        let alertShown = deferFulfillment(context.$viewState) { $0.bindings.alertInfo != nil }
        context.send(viewAction: .cancelAccountRecovery)
        try await alertShown.fulfill()
        
        // When the owner confirms.
        let errorShown = deferFulfillment(context.$viewState) { $0.bindings.alertInfo?.message == L10n.screenAccountRecoveryCancelFailed }
        context.alertInfo?.secondaryButton?.action?()
        try await errorShown.fulfill()
        
        // Then the banner is still there.
        XCTAssertEqual(identityService.cancelCalls, 1)
        XCTAssertEqual(context.viewState.accountRecoveryBanner, recovery)
    }
    
    func testAccountRecoveryBannerMessageSaysWhenItCanBeFinished() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let later = now.addingTimeInterval(3 * 24 * 60 * 60)
        
        // A date, never a clock time: an exact minute would read as a deadline to sit through, and
        // it would publish when the account was last used.
        XCTAssertEqual(HomeScreenAccountRecoveryBanner.message(for: .init(completableAt: later, expiresAt: nil), now: now),
                       L10n.screenAccountRecoveryBannerMessageLater(later.formatted(date: .long, time: .omitted)))
        XCTAssertFalse(HomeScreenAccountRecoveryBanner.message(for: .init(completableAt: later, expiresAt: nil), now: now)
            .contains(later.formatted(date: .omitted, time: .shortened)))

        // The day it names is the day it can be finished, not the day after. The server sends an
        // exact instant and only its date is shown, so "after <date>" would hand the owner a day
        // they do not have on the one surface whose job is to get them to cancel in time. The year
        // stays with it: both apps print the same shape for the same recovery.
        let laterMessage = HomeScreenAccountRecoveryBanner.message(for: .init(completableAt: later, expiresAt: nil), now: now)
        XCTAssertTrue(laterMessage.contains(later.formatted(.dateTime.year())))
        XCTAssertFalse(laterMessage.lowercased().contains("after"))
        XCTAssertEqual(HomeScreenAccountRecoveryBanner.message(for: .init(completableAt: now, expiresAt: nil), now: now),
                       L10n.screenAccountRecoveryBannerMessageNow)
        XCTAssertEqual(HomeScreenAccountRecoveryBanner.message(for: .init(completableAt: nil, expiresAt: nil), now: now),
                       L10n.screenAccountRecoveryBannerMessageGeneric)
    }
    
    func testAccountRecoveryReadDelayFollowsTheNextMomentOfTheRecovery() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let interval = Duration.seconds(15 * 60)
        
        // Nothing live, or nothing dated: the regular interval.
        XCTAssertEqual(HomeScreenViewModel.accountRecoveryReadDelay(for: nil, now: now), interval)
        XCTAssertEqual(HomeScreenViewModel.accountRecoveryReadDelay(for: .init(completableAt: nil, expiresAt: nil), now: now), interval)
        
        // Finishable before the next tick: read a second after that moment.
        XCTAssertEqual(HomeScreenViewModel.accountRecoveryReadDelay(for: .init(completableAt: now.addingTimeInterval(180),
                                                                               expiresAt: now.addingTimeInterval(360)),
                                                                    now: now),
                       .seconds(181))
        
        // Finishable already and running out before the next tick: read a second after it runs out.
        XCTAssertEqual(HomeScreenViewModel.accountRecoveryReadDelay(for: .init(completableAt: now.addingTimeInterval(-60),
                                                                               expiresAt: now.addingTimeInterval(120)),
                                                                    now: now),
                       .seconds(121))
        
        // Both moments further away than the next tick: the regular interval.
        XCTAssertEqual(HomeScreenViewModel.accountRecoveryReadDelay(for: .init(completableAt: now.addingTimeInterval(3 * 24 * 60 * 60),
                                                                               expiresAt: now.addingTimeInterval(10 * 24 * 60 * 60)),
                                                                    now: now),
                       interval)
        
        // Both moments passed, or arriving right now, while the server still reports it: the regular interval.
        XCTAssertEqual(HomeScreenViewModel.accountRecoveryReadDelay(for: .init(completableAt: now.addingTimeInterval(-120),
                                                                               expiresAt: now.addingTimeInterval(-60)),
                                                                    now: now),
                       interval)
        XCTAssertEqual(HomeScreenViewModel.accountRecoveryReadDelay(for: .init(completableAt: nil, expiresAt: now), now: now), interval)
    }
    
    func testTheBannerComesDownWhenTheRecoveryRunsOutBeforeTheNextTick() async throws {
        // Given a recovery that runs out well before the next regular read, reported by a session start
        // read that comes back only after the timer has started waiting with no banner up.
        let recovery = PendingAccountRecovery(completableAt: nil, expiresAt: Date.now.addingTimeInterval(1))
        setupViewModel(identityServiceStatus: Self.status(pendingAccountRecovery: recovery))
        identityService.holdsStatusReads = true
        try await waitUntil { self.identityService.securityStatusCalls == 1 }
        try await Task.sleep(for: .milliseconds(50))
        identityService.holdsStatusReads = false
        let bannerShown = deferFulfillment(context.$viewState) { $0.accountRecoveryBanner != nil }
        identityService.releaseHeldStatusReads()
        try await bannerShown.fulfill()
        XCTAssertEqual(identityService.securityStatusCalls, 1)
        
        // When it runs out on the server.
        identityService.status = Self.status(pendingAccountRecovery: nil)
        
        // Then the report is read again just after that moment and the banner comes down.
        try await deferFulfillment(context.$viewState, timeout: 5) { $0.accountRecoveryBanner == nil }.fulfill()
        XCTAssertEqual(identityService.securityStatusCalls, 2)
    }
    
    func testAFailedReadIsFollowedByAnEarlyReRead() async throws {
        // Given a report that cannot be read at session start, like a 401 for an expired access token.
        setupViewModel(identityServiceStatus: nil, securityStatusRetryDelay: .milliseconds(50))
        try await waitUntil { self.identityService.securityStatusCalls == 1 }
        
        // When the report can be read again.
        let recovery = PendingAccountRecovery(completableAt: nil, expiresAt: nil)
        identityService.status = Self.status(pendingAccountRecovery: recovery)
        
        // Then it is read again soon, not at the next tick, and the banner appears.
        try await deferFulfillment(context.$viewState, timeout: 5) { $0.accountRecoveryBanner != nil }.fulfill()
        XCTAssertEqual(identityService.securityStatusCalls, 2)
        XCTAssertEqual(context.viewState.accountRecoveryBanner, recovery)
    }
    
    func testFailedReadsScheduleOneReRead() async throws {
        // Given a report that cannot be read at session start.
        setupViewModel(identityServiceStatus: nil, securityStatusRetryDelay: .milliseconds(200))
        try await waitUntil { self.identityService.securityStatusCalls == 1 }
        
        // When two foreground reads fail too before the re-read is due.
        notificationCenter.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        notificationCenter.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await waitUntil { self.identityService.securityStatusCalls == 3 }
        
        // Then only one re-read follows, and when it fails as well it is not retried again.
        try await waitUntil { self.identityService.securityStatusCalls == 4 }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(identityService.securityStatusCalls, 4)
    }
    
    func testASuccessfulReadDropsThePendingReRead() async throws {
        // Given a report that could not be read at session start.
        setupViewModel(identityServiceStatus: nil, securityStatusRetryDelay: .milliseconds(200))
        try await waitUntil { self.identityService.securityStatusCalls == 1 }
        
        // When a foreground read succeeds before the re-read is due.
        identityService.status = Self.status(pendingAccountRecovery: nil)
        notificationCenter.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await waitUntil { self.identityService.securityStatusCalls == 2 }
        
        // Then there is nothing left to re-read.
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(identityService.securityStatusCalls, 2)
    }
    
    // MARK: - Helpers
    
    private static func status(pendingAccountRecovery: PendingAccountRecovery?) -> AccountSecurityStatus {
        AccountSecurityStatus(hasPin: false,
                              passkeyRegistered: false,
                              preferredFactor: nil,
                              phoneChangeStepUpFactors: [],
                              pinStepUpHoldRemainingSeconds: nil,
                              pendingAccountRecovery: pendingAccountRecovery)
    }
    
    /// For state that is not published: polls until `condition` holds or a second has passed.
    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the condition", file: file, line: line)
    }
    
    private func setupViewModel(securityStatePublisher: CurrentValuePublisher<SessionSecurityState, Never>? = nil,
                                withInvites: Bool = false,
                                identityServiceStatus: AccountSecurityStatus? = AccountSecurityStatus(hasPin: true,
                                                                                                      passkeyRegistered: false,
                                                                                                      preferredFactor: .pin,
                                                                                                      phoneChangeStepUpFactors: [],
                                                                                                      pinStepUpHoldRemainingSeconds: nil),
                                securityStatusRetryDelay: Duration = .seconds(30)) {
        var rooms: [RoomSummary] = .mockRooms
        if withInvites {
            rooms += .mockInvites
        }
        
        roomSummaryProvider = RoomSummaryProviderMock(.init(state: .loaded(rooms)))
        
        clientProxy = ClientProxyMock(.init(userID: "@mock:client.com",
                                            roomSummaryProvider: roomSummaryProvider))
        clientProxy.accessToken = "access-token"
        if withInvites {
            clientProxy.joinRoomViaReturnValue = .success(())
            clientProxy.joinRoomAliasReturnValue = .success(())
            clientProxy.roomForIdentifierClosure = { _ in .invited(InvitedRoomProxyMock(.init())) }
        }
        
        let userSession = UserSessionMock(.init(clientProxy: clientProxy))
        if let securityStatePublisher {
            userSession.sessionSecurityStatePublisher = securityStatePublisher
        }
        
        notificationManager = NotificationManagerMock()
        identityService = HomeScreenIdentityServiceStub(status: identityServiceStatus)
        notificationCenter = NotificationCenter()
        userIndicatorController = UserIndicatorControllerMock()
        
        viewModel = HomeScreenViewModel(userSession: userSession,
                                        selectedRoomPublisher: CurrentValueSubject<String?, Never>(nil).asCurrentValuePublisher(),
                                        appSettings: appSettings,
                                        analyticsService: ServiceLocator.shared.analytics,
                                        notificationManager: notificationManager,
                                        userIndicatorController: userIndicatorController,
                                        identityServiceClient: identityService,
                                        notificationCenter: notificationCenter,
                                        securityStatusRetryDelay: securityStatusRetryDelay)
    }
}

// MARK: - Stub

/// GUA FORK: the identity service as the home screen sees it: a security report to read and a
/// recovery to cancel. Cancelling clears the pending recovery, as the server does, unless a test
/// says otherwise.
@MainActor
private final class HomeScreenIdentityServiceStub: IdentityServiceClientProtocol {
    /// `nil` stands for a report that could not be read.
    var status: AccountSecurityStatus?
    var cancelError: Error?
    var cancelClearsRecovery = true
    /// While set, reads wait for `releaseHeldStatusReads()`, like reads on a slow network.
    var holdsStatusReads = false
    private var heldStatusReads: [CheckedContinuation<Void, Never>] = []
    private(set) var securityStatusCalls = 0
    private(set) var securityStatusReturns = 0
    private(set) var cancelCalls = 0

    init(status: AccountSecurityStatus?) {
        self.status = status
    }

    func securityStatus(accessToken: String) async throws -> AccountSecurityStatus {
        securityStatusCalls += 1
        // A read reports the account as it was when the request reached the server.
        let status = status
        if holdsStatusReads {
            await withCheckedContinuation { heldStatusReads.append($0) }
        }
        securityStatusReturns += 1
        guard let status else { throw IdentityServiceError.server(status: 500, message: nil) }
        return status
    }

    func releaseHeldStatusReads() {
        let reads = heldStatusReads
        heldStatusReads = []
        reads.forEach { $0.resume() }
    }

    func cancelAccountRecovery(accessToken: String) async throws {
        cancelCalls += 1
        if let cancelError {
            throw cancelError
        }
        if cancelClearsRecovery {
            status?.pendingAccountRecovery = nil
        }
    }

    func lookupContacts(accessToken: String, phones: [String]) async throws -> [ContactMatch] {
        []
    }

    func startAccountReauth(accessToken: String, phone: String, language: String?) async throws { }
    func verifyAccountReauth(accessToken: String, phone: String, code: String, operation: ReauthOperation) async throws -> String {
        ""
    }

    func deactivateAccount(accessToken: String, reauthToken: String, eraseData: Bool) async throws { }
    func resetIdentityCredentials(accessToken: String, reauthToken: String) async throws -> IdentityResetCredentials {
        IdentityResetCredentials(userId: "", password: "")
    }

    func startPinChange(accessToken: String,
                        phone: String,
                        currentPin: String?,
                        passkeyStepUpID: String?,
                        passkeyAssertion: PasskeyAssertion?) async throws -> String {
        ""
    }

    func completePinChange(accessToken: String, challengeId: String, otpCode: String, newPin: String) async throws { }
    func startPasskeyStepUp(accessToken: String) async throws -> PasskeyStepUpOptions {
        throw IdentityServiceError.passkeyStepUpUnavailable
    }

    func startPhoneChange(accessToken: String,
                          reauthToken: String,
                          newPhone: String,
                          pin: String?,
                          passkeyStepUpID: String?,
                          passkeyAssertion: PasskeyAssertion?,
                          language: String?) async throws -> PhoneChangeChallenge {
        PhoneChangeChallenge(challengeID: "", otpExpiresInSeconds: 0)
    }

    func completePhoneChange(accessToken: String, challengeId: String, code: String) async throws { }
    func startPasskeyEnrollment(accessToken: String, redirectURI: String?) async throws -> URL {
        URL(string: "https://example.invalid")!
    }

    func startPinEnrollment(accessToken: String, redirectURI: String?) async throws -> URL {
        URL(string: "https://example.invalid")!
    }
}

private extension [HomeScreenRoom] {
    var invites: [HomeScreenRoom] {
        filter { room in
            if case .invite = room.type {
                true
            } else {
                false
            }
        }
    }
}
