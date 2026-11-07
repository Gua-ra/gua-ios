//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import Foundation
import Testing
import UIKit

@MainActor
final class HomeScreenViewModelTests {
    var viewModel: HomeScreenViewModelProtocol!
    var context: HomeScreenViewModelType.Context! {
        viewModel.context
    }
    
    var clientProxy: ClientProxyMock!
    var roomSummaryProvider: RoomSummaryProviderMock!
    var notificationService: NotificationServiceMock!
    private let userSettings: UserSettings
    private var identityService: HomeScreenIdentityServiceStub!
    private var notificationCenter: NotificationCenter!
    private var userIndicatorController: UserIndicatorControllerMock!
    
    var cancellables = Set<AnyCancellable>()
    
    init() {
        userSettings = UserSettings.mock()
    }
    
    @Test
    func selectRoom() async {
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
        #expect(correctResult)
        #expect(mockRoomID == selectedRoomID)
    }
    
    @Test
    func tapUserAvatar() async {
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
        #expect(correctResult)
    }
    
    @Test
    func leaveRoomAlert() async throws {
        setupViewModel()
        
        let mockRoomID = "1"
        
        clientProxy.roomForIdentifierClosure = { _ in .joined(JoinedRoomProxyMock(.init(id: mockRoomID, name: "Some room"))) }
        
        let deferred = deferFulfillment(context.$viewState) { value in
            value.bindings.leaveRoomAlertItem != nil
        }
        
        context.send(viewAction: .leaveRoom(roomIdentifier: mockRoomID))
        
        try await deferred.fulfill()
        
        #expect(context.leaveRoomAlertItem?.roomID == mockRoomID)
    }
    
    @Test
    func leaveRoomError() async throws {
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
        
        #expect(context.alertInfo != nil)
    }
    
    @Test
    func leaveRoomSuccess() async throws {
        setupViewModel()
        
        let mockRoomID = "1"
        
        let room = JoinedRoomProxyMock(.init(id: mockRoomID, name: "Some room"))
        room.leaveRoomClosure = { .success(()) }
        
        clientProxy.roomForIdentifierClosure = { _ in .joined(room) }
        
        let deferred = deferFulfillment(viewModel.actions) { action in
            if case .roomLeft(let roomIdentifier) = action {
                return roomIdentifier == mockRoomID
            }
            return false
        }
        
        context.send(viewAction: .confirmLeaveRoom(roomIdentifier: mockRoomID))
        try await deferred.fulfill()
        #expect(context.alertInfo == nil)
    }
    
    @Test
    func showRoomDetails() async {
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
        #expect(context.alertInfo == nil)
        #expect(correctResult)
    }
    
    @Test
    func filters() async throws {
        setupViewModel()
        
        context.filtersState.activateFilter(.people)
        try await Task.sleep(for: .milliseconds(100))
        #expect(roomSummaryProvider.roomListPublisher.value.count == 2)
        #expect(roomSummaryProvider.roomListPublisher.value.first?.name == "Foundation and Earth")
    }
    
    @Test
    func search() async throws {
        setupViewModel()
        
        context.isSearchFieldFocused = true
        context.searchQuery = "lude to Found"
        try await Task.sleep(for: .milliseconds(100))
        #expect(roomSummaryProvider.roomListPublisher.value.first?.name == "Prelude to Foundation")
        #expect(roomSummaryProvider.roomListPublisher.value.count == 1)
    }
    
    @Test
    func filtersEmptyState() async throws {
        setupViewModel()
        
        context.filtersState.activateFilter(.people)
        context.filtersState.activateFilter(.favourites)
        try await Task.sleep(for: .milliseconds(100))
        #expect(context.viewState.shouldShowEmptyFilterState)
        context.isSearchFieldFocused = true
        #expect(!context.viewState.shouldShowEmptyFilterState)
    }
    
    @Test
    func setUpRecoveryBannerState() async throws {
        // Given a view model without a visible security banner.
        let securityStateStateSubject = CurrentValueSubject<SessionSecurityState, Never>(.init(verificationState: .verified, recoveryState: .unknown))
        setupViewModel(securityStatePublisher: securityStateStateSubject.asCurrentValuePublisher())
        #expect(context.viewState.securityBannerMode == .none)
        
        // When the recovery state comes through as disabled.
        var deferred = deferFulfillment(context.$viewState) { $0.securityBannerMode == .show(.recoveryOutOfSync) }
        securityStateStateSubject.send(.init(verificationState: .verified, recoveryState: .disabled))
        
        // Then the banner should be the one that finishes setup silently. GUA FORK: .disabled
        // used to show .setUpRecovery, whose flow hands the user a recovery key to write down,
        // and .disabled is the state an identity reset leaves behind.
        try await deferred.fulfill()
        
        // When the recovery is enabled.
        deferred = deferFulfillment(context.$viewState) { $0.securityBannerMode == .none }
        securityStateStateSubject.send(.init(verificationState: .verified, recoveryState: .enabled))
        
        // Then the banner should no longer be shown.
        try await deferred.fulfill()
    }
    
    @Test
    func theBannerButtonRoutesToTheStagedRepair() {
        // The banner is the ONLY encryption affordance a user has, so its button must go to the
        // staged repair. If it points at .resetEncryption again, every tap skips straight to
        // "Some previous messages can't be recovered" and the silent path becomes dead code.
        #expect(HomeScreenRecoveryKeyConfirmationBanner.State.recoveryOutOfSync.primaryAction == .confirmRecoveryKey)
    }
    
    @Test
    func finishSetupRepairsWithoutAskingToReset() async throws {
        // Given a device whose key storage can still be repaired without discarding the backup.
        setupViewModel()
        let secureBackupController = try #require(clientProxy.secureBackupController as? SecureBackupControllerMock)
        secureBackupController.repairWithoutResetReturnValue = .repaired
        
        var receivedAction: HomeScreenViewModelAction?
        viewModel.actions.sink { receivedAction = $0 }.store(in: &cancellables)
        
        // When the user taps the banner's button. Drive it through the banner's own primaryAction
        // rather than naming the action: sending .confirmRecoveryKey directly is what let the
        // banner sit on .resetEncryption for a whole release with these tests green.
        context.send(viewAction: HomeScreenRecoveryKeyConfirmationBanner.State.recoveryOutOfSync.primaryAction)
        try await Task.sleep(for: .milliseconds(200))
        
        // Then it repairs silently and never offers the destructive reset.
        #expect(secureBackupController.repairWithoutResetCallsCount == 1)
        #expect(receivedAction == nil)
    }
    
    @Test
    func finishSetupAsksBeforeResettingWhenRepairIsImpossible() async throws {
        // Given a device that cannot be finished without discarding the backup.
        setupViewModel()
        let secureBackupController = try #require(clientProxy.secureBackupController as? SecureBackupControllerMock)
        secureBackupController.repairWithoutResetReturnValue = .resetRequired
        
        var receivedAction: HomeScreenViewModelAction?
        viewModel.actions.sink { receivedAction = $0 }.store(in: &cancellables)
        
        // When the user taps the banner's button, via the banner's own primaryAction.
        context.send(viewAction: HomeScreenRecoveryKeyConfirmationBanner.State.recoveryOutOfSync.primaryAction)
        try await Task.sleep(for: .milliseconds(200))
        
        // Then the reset is disclosed rather than performed silently.
        #expect(secureBackupController.repairWithoutResetCallsCount == 1)
        #expect(receivedAction == .presentEncryptionResetScreen)
    }
    
    @Test
    func dismissSetUpRecoveryBannerState() async throws {
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
        let failure = deferFailure(context.$viewState, timeout: .seconds(1)) { $0.securityBannerMode != .dismissed }
        securityStateStateSubject.send(.init(verificationState: .verified, recoveryState: .disabled))
        try await failure.fulfill()
    }
    
    @Test
    func outOfSyncRecoveryBannerState() async throws {
        // Given a view model without a visible security banner.
        let securityStateStateSubject = CurrentValueSubject<SessionSecurityState, Never>(.init(verificationState: .verified, recoveryState: .unknown))
        setupViewModel(securityStatePublisher: securityStateStateSubject.asCurrentValuePublisher())
        #expect(context.viewState.securityBannerMode == .none)
        
        // When the recovery state comes through as incomplete.
        var deferred = deferFulfillment(context.$viewState) { $0.securityBannerMode == .show(.recoveryOutOfSync) }
        securityStateStateSubject.send(.init(verificationState: .verified, recoveryState: .incomplete))
        
        // Then the banner should be shown for out of sync recovery.
        try await deferred.fulfill()
        
        // When the recovery is enabled.
        deferred = deferFulfillment(context.$viewState) { $0.securityBannerMode == .none }
        securityStateStateSubject.send(.init(verificationState: .verified, recoveryState: .enabled))
        
        // Then the banner should no longer be shown.
        try await deferred.fulfill()
    }
    
    @Test
    func inviteUnreadBadge() async throws {
        setupViewModel(invites: .rooms)
        var invites = context.viewState.rooms.invites
        #expect(invites.count == 2)
        
        for invite in invites {
            #expect(invite.badges.isDotShown)
        }
        
        let deferred = deferFulfillment(context.$viewState) { state in
            state.rooms.contains { room in
                room.roomID == invites[0].roomID && room.badges.isDotShown == false
            }
        }
        userSettings.account.seenInvites = Set(invites.compactMap(\.roomID))
        try await deferred.fulfill()
        invites = context.viewState.rooms.invites
        
        for invite in invites {
            #expect(!invite.badges.isDotShown)
        }
    }
    
    @Test
    func acceptInvite() async throws {
        setupViewModel(invites: .rooms)
        
        let invitedRoomIDs = context.viewState.rooms.invites.compactMap(\.roomID)
        userSettings.account.seenInvites = Set(invitedRoomIDs)
        #expect(invitedRoomIDs.count == 2)
        
        let deferred = deferFulfillment(viewModel.actions) { $0 == .presentRoom(roomIdentifier: invitedRoomIDs[0]) }
        context.send(viewAction: .acceptInvite(roomIdentifier: invitedRoomIDs[0]))
        try await deferred.fulfill()
        
        #expect(userSettings.account.seenInvites == [invitedRoomIDs[1]])
        #expect(!notificationService.removeDeliveredMessageNotificationsForCalled, "The notification will be dismissed when opening the room.")
    }
    
    @Test
    func acceptingASpaceInviteOpensItsJoinScreen() async throws {
        setupViewModel(invites: .spaces)
        let invitedRoomID = try #require(context.viewState.rooms.invites.compactMap(\.roomID).first)
        
        let deferred = deferFulfillment(viewModel.actions) { $0 == .presentRoom(roomIdentifier: invitedRoomID) }
        context.send(viewAction: .acceptInvite(roomIdentifier: invitedRoomID))
        try await deferred.fulfill()
        
        #expect(!clientProxy.joinRoomViaCalled, "The join screen offers the choice, so Chats never joins a space directly.")
        #expect(!clientProxy.setAccountDataTypeContentCalled)
        #expect(!userSettings.app.spacesEnabled)
    }
    
    @Test
    func declineInvite() async throws {
        setupViewModel(invites: .rooms)
        let invitedRoomIDs = context.viewState.rooms.invites.compactMap(\.roomID)
        userSettings.account.seenInvites = Set(invitedRoomIDs)
        #expect(invitedRoomIDs.count == 2)
        
        let deferred = deferFulfillment(context.$viewState) { $0.bindings.alertInfo != nil }
        context.send(viewAction: .declineInvite(roomIdentifier: invitedRoomIDs[0]))
        try await deferred.fulfill()
        
        var rejectCalled = false
        clientProxy.roomForIdentifierClosure = { _ in
            let roomProxy = InvitedRoomProxyMock(.init())
            roomProxy.rejectInvitationClosure = {
                rejectCalled = true
                return .success(())
            }
            
            return .invited(roomProxy)
        }
        context.viewState.bindings.alertInfo?.verticalButtons?[0].action?()
        
        // Wait for the async action to complete
        try await Task.sleep(for: .milliseconds(100))
        #expect(rejectCalled)
        
        #expect(userSettings.account.seenInvites == [invitedRoomIDs[1]])
        #expect(notificationService.removeDeliveredMessageNotificationsForCalled)
        #expect(notificationService.removeDeliveredMessageNotificationsForReceivedInvocations == [invitedRoomIDs[0]])
    }
    
    @Test
    func declineAndBlockInvite() async throws {
        setupViewModel(invites: .rooms)
        let invitedRoomIDs = context.viewState.rooms.invites.compactMap(\.roomID)
        userSettings.account.seenInvites = Set(invitedRoomIDs)
        #expect(invitedRoomIDs.count == 2)
        
        let deferred = deferFulfillment(context.$viewState) { $0.bindings.alertInfo != nil }
        context.send(viewAction: .declineInvite(roomIdentifier: invitedRoomIDs[0]))
        try await deferred.fulfill()
        
        let deferredAction = deferFulfillment(viewModel.actions) { $0 == .presentDeclineAndBlock(userID: RoomMemberProxyMock.mockCharlie.userID, roomID: invitedRoomIDs[0]) }
        context.viewState.bindings.alertInfo?.secondaryButton?.action?()
        try await deferredAction.fulfill()
    }
    
    @Test
    func newSoundBanner() {
        userSettings.app.hasSeenNewSoundBanner = false
        
        setupViewModel()
        #expect(context.viewState.shouldShowBanner)
        #expect(context.viewState.shouldShowNewSoundBanner)
        
        context.send(viewAction: .dismissNewSoundBanner)
        #expect(!context.viewState.shouldShowBanner)
        #expect(!context.viewState.shouldShowNewSoundBanner)
        #expect(userSettings.app.hasSeenNewSoundBanner)
    }
    
    @Test
    func multiAccountAnnouncement() async throws {
        userSettings.app.multiAccountEnabled = true
        setupViewModel()
        
        // Arming it after the view model exists (Developer options) doesn't present it on its own.
        userSettings.app.hasSeenMultiAccountAnnouncement = false
        let deferredFailure = deferFailure(context.$viewState, timeout: .seconds(1)) { $0.bindings.isPresentingMultiAccountAnnouncement }
        try await deferredFailure.fulfill()
        
        let deferred = deferFulfillment(context.$viewState) { $0.bindings.isPresentingMultiAccountAnnouncement }
        context.send(viewAction: .screenAppeared)
        try await deferred.fulfill()
        #expect(!userSettings.app.hasSeenMultiAccountAnnouncement)
        
        context.send(viewAction: .multiAccountAnnouncementAppeared)
        #expect(userSettings.app.hasSeenMultiAccountAnnouncement)
        #expect(context.viewState.bindings.isPresentingMultiAccountAnnouncement)
        
        // A swipe down dismisses it without any of the announcement's actions.
        context.isPresentingMultiAccountAnnouncement = false
        let deferredReappearance = deferFailure(context.$viewState, timeout: .seconds(1)) { $0.bindings.isPresentingMultiAccountAnnouncement }
        context.send(viewAction: .screenAppeared)
        try await deferredReappearance.fulfill()
    }
    
    @Test(arguments: [HomeScreenViewAction.dismissMultiAccountAnnouncement, .addAccount])
    func multiAccountAnnouncementActionsDismissIt(_ action: HomeScreenViewAction) async throws {
        userSettings.app.multiAccountEnabled = true
        userSettings.app.hasSeenMultiAccountAnnouncement = false
        setupViewModel()
        
        let deferred = deferFulfillment(context.$viewState) { $0.bindings.isPresentingMultiAccountAnnouncement }
        context.send(viewAction: .screenAppeared)
        try await deferred.fulfill()
        
        context.send(viewAction: action)
        #expect(!context.viewState.bindings.isPresentingMultiAccountAnnouncement)
    }
    
    @Test(arguments: MultiAccountAnnouncementHiddenCase.allCases)
    func multiAccountAnnouncementHidden(_ hiddenCase: MultiAccountAnnouncementHiddenCase) async throws {
        userSettings.app.multiAccountEnabled = hiddenCase != .flagOff
        userSettings.app.hasSeenMultiAccountAnnouncement = hiddenCase == .alreadySeen
        let verificationState: SessionVerificationState = switch hiddenCase {
        case .unverified: .unverified
        case .unknownVerificationState: .unknown
        case .flagOff, .alreadySeen: .verified
        }
        let securityStateSubject = CurrentValueSubject<SessionSecurityState, Never>(.init(verificationState: verificationState, recoveryState: .enabled))
        setupViewModel(securityStatePublisher: securityStateSubject.asCurrentValuePublisher())
        
        let deferred = deferFailure(context.$viewState, timeout: .seconds(1)) { $0.bindings.isPresentingMultiAccountAnnouncement }
        context.send(viewAction: .screenAppeared)
        try await deferred.fulfill()
        #expect(userSettings.app.hasSeenMultiAccountAnnouncement == (hiddenCase == .alreadySeen))
    }
    
    @Test
    func multiAccountAnnouncementPresentsOnTheNextAppearanceOnceVerified() async throws {
        userSettings.app.multiAccountEnabled = true
        userSettings.app.hasSeenMultiAccountAnnouncement = false
        let securityStateSubject = CurrentValueSubject<SessionSecurityState, Never>(.init(verificationState: .unverified, recoveryState: .enabled))
        setupViewModel(securityStatePublisher: securityStateSubject.asCurrentValuePublisher())
        
        let deferredFailure = deferFailure(context.$viewState, timeout: .seconds(1)) { $0.bindings.isPresentingMultiAccountAnnouncement }
        context.send(viewAction: .screenAppeared)
        try await deferredFailure.fulfill()
        
        // Becoming verified doesn't present it on its own…
        securityStateSubject.send(.init(verificationState: .verified, recoveryState: .enabled))
        let deferredVerifiedFailure = deferFailure(context.$viewState, timeout: .seconds(1)) { $0.bindings.isPresentingMultiAccountAnnouncement }
        try await deferredVerifiedFailure.fulfill()
        
        // …the room list appearing again does, e.g. once the identity confirmation cover is dismissed.
        let deferred = deferFulfillment(context.$viewState) { $0.bindings.isPresentingMultiAccountAnnouncement }
        context.send(viewAction: .screenAppeared)
        try await deferred.fulfill()
    }
    
    @Test
    func multiAccountAnnouncementIsMarkedSeenWithSeveralAccounts() async throws {
        userSettings.app.multiAccountEnabled = true
        userSettings.app.hasSeenMultiAccountAnnouncement = false
        setupViewModel(otherAccountUserIDs: ["@other:client.com"])
        
        let deferred = deferFailure(context.$viewState, timeout: .seconds(1)) { $0.bindings.isPresentingMultiAccountAnnouncement }
        context.send(viewAction: .screenAppeared)
        try await deferred.fulfill()
        
        #expect(userSettings.app.hasSeenMultiAccountAnnouncement)
    }
    
    // MARK: - Account recovery banner
    
    @Test
    func accountRecoveryBannerShowsWhilePendingEvenWhenThePinReminderIsSnoozed() async throws {
        // Given an account with no factor and a live recovery, and a PIN reminder the user snoozed.
        userSettings.app.pinSetupReminderSnoozedUntil = Date().addingTimeInterval(24 * 60 * 60)
        let recovery = PendingAccountRecovery(completableAt: Date(timeIntervalSince1970: 2_000_000_000),
                                              expiresAt: Date(timeIntervalSince1970: 2_000_600_000))
        
        // When the home screen reads the report at session start.
        setupViewModel(identityServiceStatus: Self.status(pendingAccountRecovery: recovery))
        try await deferFulfillment(context.$viewState) { $0.accountRecoveryBanner != nil }.fulfill()
        
        // Then the recovery banner is up and the snooze only kept the nudge away.
        #expect(context.viewState.accountRecoveryBanner == recovery)
        #expect(!context.viewState.pinSetupReminderVisible)
    }
    
    @Test
    func noAccountRecoveryBannerWhenNothingIsPending() async throws {
        // Given an account with no factor and nothing pending.
        setupViewModel(identityServiceStatus: Self.status(pendingAccountRecovery: nil))
        try await deferFulfillment(context.$viewState) { $0.pinSetupReminderVisible }.fulfill()
        
        // Then only the nudge shows.
        #expect(context.viewState.accountRecoveryBanner == nil)
    }
    
    @Test
    func foregroundRefetchesTheAccountRecoveryStatus() async throws {
        // Given a home screen that read a report with nothing pending.
        setupViewModel(identityServiceStatus: Self.status(pendingAccountRecovery: nil))
        try await waitUntil { self.identityService.securityStatusCalls == 1 }
        #expect(context.viewState.accountRecoveryBanner == nil)
        
        // When someone starts a recovery while the app is in the background and it comes back.
        let recovery = PendingAccountRecovery(completableAt: nil, expiresAt: nil)
        identityService.status = Self.status(pendingAccountRecovery: recovery)
        let deferred = deferFulfillment(context.$viewState) { $0.accountRecoveryBanner != nil }
        notificationCenter.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await deferred.fulfill()
        
        // Then the report is read again and the banner appears.
        #expect(identityService.securityStatusCalls == 2)
        #expect(context.viewState.accountRecoveryBanner == recovery)
    }
    
    @Test
    func aFailedRefetchKeepsTheAccountRecoveryBanner() async throws {
        // Given a banner for a live recovery.
        let recovery = PendingAccountRecovery(completableAt: nil, expiresAt: nil)
        setupViewModel(identityServiceStatus: Self.status(pendingAccountRecovery: recovery))
        try await deferFulfillment(context.$viewState) { $0.accountRecoveryBanner != nil }.fulfill()
        
        // When the report cannot be read on the next foreground.
        identityService.status = nil
        notificationCenter.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await waitUntil { self.identityService.securityStatusCalls == 2 }
        
        // Then the banner stays: a bad network is no reason to hide it.
        #expect(context.viewState.accountRecoveryBanner == recovery)
    }
    
    @Test
    func cancelAccountRecoveryAsksFirstThenCancelsRefetchesAndConfirms() async throws {
        // Given a banner for a live recovery.
        setupViewModel(identityServiceStatus: Self.status(pendingAccountRecovery: PendingAccountRecovery(completableAt: nil, expiresAt: nil)))
        try await deferFulfillment(context.$viewState) { $0.accountRecoveryBanner != nil }.fulfill()
        
        // When the owner taps Cancel recovery.
        let alertShown = deferFulfillment(context.$viewState) { $0.bindings.alertInfo != nil }
        context.send(viewAction: .cancelAccountRecovery)
        try await alertShown.fulfill()
        
        // Then nothing is cancelled until they confirm.
        #expect(context.alertInfo?.title == L10n.screenAccountRecoveryCancelConfirmTitle)
        #expect(identityService.cancelCalls == 0)
        
        // When they confirm.
        let callsBeforeCancel = identityService.securityStatusCalls
        let bannerGone = deferFulfillment(context.$viewState) { $0.accountRecoveryBanner == nil }
        context.alertInfo?.secondaryButton?.action?()
        try await bannerGone.fulfill()
        try await waitUntil { self.userIndicatorController.submitIndicatorDelayReceivedArguments?.indicator.title == L10n.screenAccountRecoveryCancelled }
        
        // Then the server is asked once, the report is read again, and the owner is told.
        #expect(identityService.cancelCalls == 1)
        #expect(identityService.securityStatusCalls == callsBeforeCancel + 1)
        #expect(context.viewState.accountRecoveryBanner == nil)
    }
    
    @Test
    func aStatusReadThatStartedBeforeACancelDoesNotBringTheBannerBack() async throws {
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
        #expect(context.viewState.accountRecoveryBanner == nil)
        
        // And the old read, which still saw the recovery as pending, finally returns.
        identityService.releaseHeldStatusReads()
        try await waitUntil { self.identityService.securityStatusReturns == 3 }
        try await Task.sleep(for: .milliseconds(100))
        
        // Then it describes the account as it was before the cancel and is ignored.
        #expect(identityService.cancelCalls == 1)
        #expect(context.viewState.accountRecoveryBanner == nil)
    }
    
    @Test
    func cancelThatLeavesTheRecoveryLiveKeepsTheBannerAndSaysSo() async throws {
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
        #expect(identityService.cancelCalls == 1)
        #expect(identityService.securityStatusCalls == callsBeforeCancel + 1)
        #expect(context.viewState.accountRecoveryBanner == recovery)
        #expect(userIndicatorController.submitIndicatorDelayReceivedArguments?.indicator.title != L10n.screenAccountRecoveryCancelled)
    }
    
    @Test
    func cancelAccountRecoveryFailureKeepsTheBannerAndSaysSo() async throws {
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
        #expect(identityService.cancelCalls == 1)
        #expect(context.viewState.accountRecoveryBanner == recovery)
    }
    
    @Test
    func accountRecoveryBannerMessageSaysWhenItCanBeFinished() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let later = now.addingTimeInterval(3 * 24 * 60 * 60)
        
        // A date, never a clock time: an exact minute would read as a deadline to sit through, and
        // it would publish when the account was last used.
        #expect(HomeScreenAccountRecoveryBanner.message(for: .init(completableAt: later, expiresAt: nil), now: now)
            == L10n.screenAccountRecoveryBannerMessageLater(later.formatted(date: .long, time: .omitted)))
        #expect(!HomeScreenAccountRecoveryBanner.message(for: .init(completableAt: later, expiresAt: nil), now: now)
            .contains(later.formatted(date: .omitted, time: .shortened)))
        
        // The day it names is the day it can be finished, not the day after. The server sends an
        // exact instant and only its date is shown, so "after <date>" would hand the owner a day
        // they do not have on the one surface whose job is to get them to cancel in time. The year
        // stays with it: both apps print the same shape for the same recovery.
        let laterMessage = HomeScreenAccountRecoveryBanner.message(for: .init(completableAt: later, expiresAt: nil), now: now)
        #expect(laterMessage.contains(later.formatted(.dateTime.year())))
        #expect(!laterMessage.lowercased().contains("after"))
        #expect(HomeScreenAccountRecoveryBanner.message(for: .init(completableAt: now, expiresAt: nil), now: now)
            == L10n.screenAccountRecoveryBannerMessageNow)
        #expect(HomeScreenAccountRecoveryBanner.message(for: .init(completableAt: nil, expiresAt: nil), now: now)
            == L10n.screenAccountRecoveryBannerMessageGeneric)
    }
    
    @Test
    func accountRecoveryReadDelayFollowsTheNextMomentOfTheRecovery() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let interval = Duration.seconds(15 * 60)
        
        // Nothing live, or nothing dated: the regular interval.
        #expect(HomeScreenViewModel.accountRecoveryReadDelay(for: nil, now: now) == interval)
        #expect(HomeScreenViewModel.accountRecoveryReadDelay(for: .init(completableAt: nil, expiresAt: nil), now: now) == interval)
        
        // Finishable before the next tick: read a second after that moment.
        #expect(HomeScreenViewModel.accountRecoveryReadDelay(for: .init(completableAt: now.addingTimeInterval(180),
                                                                        expiresAt: now.addingTimeInterval(360)),
                                                             now: now)
                == .seconds(181))
        
        // Finishable already and running out before the next tick: read a second after it runs out.
        #expect(HomeScreenViewModel.accountRecoveryReadDelay(for: .init(completableAt: now.addingTimeInterval(-60),
                                                                        expiresAt: now.addingTimeInterval(120)),
                                                             now: now)
                == .seconds(121))
        
        // Both moments further away than the next tick: the regular interval.
        #expect(HomeScreenViewModel.accountRecoveryReadDelay(for: .init(completableAt: now.addingTimeInterval(3 * 24 * 60 * 60),
                                                                        expiresAt: now.addingTimeInterval(10 * 24 * 60 * 60)),
                                                             now: now)
                == interval)
        
        // Both moments passed, or arriving right now, while the server still reports it: the regular interval.
        #expect(HomeScreenViewModel.accountRecoveryReadDelay(for: .init(completableAt: now.addingTimeInterval(-120),
                                                                        expiresAt: now.addingTimeInterval(-60)),
                                                             now: now)
                == interval)
        #expect(HomeScreenViewModel.accountRecoveryReadDelay(for: .init(completableAt: nil, expiresAt: now), now: now) == interval)
    }
    
    @Test
    func theBannerComesDownWhenTheRecoveryRunsOutBeforeTheNextTick() async throws {
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
        #expect(identityService.securityStatusCalls == 1)
        
        // When it runs out on the server.
        identityService.status = Self.status(pendingAccountRecovery: nil)
        
        // Then the report is read again just after that moment and the banner comes down.
        try await deferFulfillment(context.$viewState, timeout: .seconds(5)) { $0.accountRecoveryBanner == nil }.fulfill()
        #expect(identityService.securityStatusCalls == 2)
    }
    
    @Test
    func aFailedReadIsFollowedByAnEarlyReRead() async throws {
        // Given a report that cannot be read at session start, like a 401 for an expired access token.
        setupViewModel(identityServiceStatus: nil, securityStatusRetryDelay: .milliseconds(50))
        try await waitUntil { self.identityService.securityStatusCalls == 1 }
        
        // When the report can be read again.
        let recovery = PendingAccountRecovery(completableAt: nil, expiresAt: nil)
        identityService.status = Self.status(pendingAccountRecovery: recovery)
        
        // Then it is read again soon, not at the next tick, and the banner appears.
        try await deferFulfillment(context.$viewState, timeout: .seconds(5)) { $0.accountRecoveryBanner != nil }.fulfill()
        #expect(identityService.securityStatusCalls == 2)
        #expect(context.viewState.accountRecoveryBanner == recovery)
    }
    
    @Test
    func failedReadsScheduleOneReRead() async throws {
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
        #expect(identityService.securityStatusCalls == 4)
    }
    
    @Test
    func aSuccessfulReadDropsThePendingReRead() async throws {
        // Given a report that could not be read at session start.
        setupViewModel(identityServiceStatus: nil, securityStatusRetryDelay: .milliseconds(200))
        try await waitUntil { self.identityService.securityStatusCalls == 1 }
        
        // When a foreground read succeeds before the re-read is due.
        identityService.status = Self.status(pendingAccountRecovery: nil)
        notificationCenter.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await waitUntil { self.identityService.securityStatusCalls == 2 }
        
        // Then there is nothing left to re-read.
        try await Task.sleep(for: .milliseconds(500))
        #expect(identityService.securityStatusCalls == 2)
    }
    
    // MARK: - Helpers
    
    enum InviteType { case rooms, spaces }
    
    enum MultiAccountAnnouncementHiddenCase: CaseIterable { case flagOff, alreadySeen, unverified, unknownVerificationState }
    
    @Test
    func roomListModeIsSetSynchronouslyOnAWarmLaunch() {
        setupViewModel()
        
        // No awaiting, the mode must not need the subscription's async delivery.
        #expect(context.viewState.roomListMode == .rooms)
    }
    
    @Test
    func roomListModeWaitsForTheRoomsToPublish() async throws {
        let (roomListSubject, stateSubject) = setupViewModelWithManualProvider()
        
        #expect(context.viewState.roomListMode == .skeletons)
        
        // The provider reports loaded before the first summaries have been published.
        let failure = deferFailure(context.$viewState, timeout: .seconds(1)) { $0.roomListMode != .skeletons }
        stateSubject.send(.loaded(totalNumberOfRooms: 8))
        try await failure.fulfill()
        
        let deferred = deferFulfillment(context.$viewState) { $0.roomListMode == .rooms }
        roomListSubject.send(.mockRooms)
        try await deferred.fulfill()
    }
    
    @Test
    func roomListModeDoesntHoldSkeletonsForAnEmptyFilteredResult() async throws {
        let (roomListSubject, stateSubject) = setupViewModelWithManualProvider()
        #expect(context.viewState.roomListMode == .skeletons)
        
        // A filter is active before anything has published and the filtered list is loaded but empty.
        context.filtersState.activateFilter(.people)
        let deferred = deferFulfillment(context.$viewState) { $0.roomListMode == .rooms }
        roomListSubject.send([])
        stateSubject.send(.loaded(totalNumberOfRooms: 8))
        try await deferred.fulfill()
    }
    
    @Test
    func roomListModeGoesStraightToTheCachedRooms() async throws {
        let (roomListSubject, _) = setupViewModelWithManualProvider(state: .loaded(totalNumberOfRooms: 8))
        #expect(context.viewState.roomListMode == .awaitingCachedRooms)
        
        let deferred = deferFulfillment(context.$viewState) { $0.roomListMode == .rooms }
        roomListSubject.send(.mockRooms)
        try await deferred.fulfill()
    }
    
    @Test
    func roomListModeShowsSkeletonsWhenTheCachedRoomsAreSlow() async throws {
        _ = setupViewModelWithManualProvider(state: .loaded(totalNumberOfRooms: 8))
        #expect(context.viewState.roomListMode == .awaitingCachedRooms)
        
        let deferred = deferFulfillment(context.$viewState) { $0.roomListMode == .skeletons }
        try await deferred.fulfill()
    }
    
    @Test
    func roomListModeDoesntReturnToSkeletonsWhenTheRoomsAreFilteredOut() async throws {
        let (roomListSubject, stateSubject) = setupViewModelWithManualProvider()
        
        stateSubject.send(.loaded(totalNumberOfRooms: 8))
        let deferred = deferFulfillment(context.$viewState) { $0.roomListMode == .rooms }
        roomListSubject.send(.mockRooms)
        try await deferred.fulfill()
        
        // A filter or a search without matches empties the list, the mode must not regress.
        let failure = deferFailure(context.$viewState, timeout: .seconds(1)) { $0.roomListMode != .rooms }
        roomListSubject.send([])
        stateSubject.send(.loaded(totalNumberOfRooms: 9))
        try await failure.fulfill()
    }
    
    private func setupViewModelWithManualProvider(state: RoomSummaryProviderState = .notLoaded) -> (CurrentValueSubject<[RoomSummary], Never>, CurrentValueSubject<RoomSummaryProviderState, Never>) {
        let roomListSubject = CurrentValueSubject<[RoomSummary], Never>([])
        let stateSubject = CurrentValueSubject<RoomSummaryProviderState, Never>(state)
        
        let provider = RoomSummaryProviderMock()
        provider.roomListPublisher = roomListSubject.asCurrentValuePublisher()
        provider.statePublisher = stateSubject.asCurrentValuePublisher()
        
        setupViewModel(roomSummaryProvider: provider)
        
        return (roomListSubject, stateSubject)
    }
    
    private static func status(pendingAccountRecovery: PendingAccountRecovery?) -> AccountSecurityStatus {
        AccountSecurityStatus(hasPin: false,
                              passkeyRegistered: false,
                              preferredFactor: nil,
                              phoneChangeStepUpFactors: [],
                              pinStepUpHoldRemainingSeconds: nil,
                              pendingAccountRecovery: pendingAccountRecovery)
    }
    
    /// For state that is not published: polls until `condition` holds or a second has passed.
    private func waitUntil(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for the condition", sourceLocation: sourceLocation)
    }
    
    private func setupViewModel(otherAccountUserIDs: [String] = [],
                                securityStatePublisher: CurrentValuePublisher<SessionSecurityState, Never>? = nil,
                                invites: InviteType? = nil,
                                roomSummaryProvider: RoomSummaryProviderMock? = nil,
                                identityServiceStatus: AccountSecurityStatus? = AccountSecurityStatus(hasPin: true,
                                                                                                      passkeyRegistered: false,
                                                                                                      preferredFactor: .pin,
                                                                                                      phoneChangeStepUpFactors: [],
                                                                                                      pinStepUpHoldRemainingSeconds: nil),
                                securityStatusRetryDelay: Duration = .seconds(30)) {
        cancellables.removeAll()
        
        var rooms: [RoomSummary] = .mockRooms
        
        switch invites {
        case .rooms:
            rooms += .mockInvites
        case .spaces:
            rooms += .mockSpaceInvites
        case nil:
            break
        }
        
        self.roomSummaryProvider = roomSummaryProvider ?? RoomSummaryProviderMock(.init(state: .loaded(rooms)))
        
        clientProxy = ClientProxyMock(.init(userID: "@mock:client.com",
                                            roomSummaryProvider: self.roomSummaryProvider))
        clientProxy.accessToken = "access-token"
        
        clientProxy.joinRoomViaReturnValue = .success(())
        clientProxy.joinRoomAliasReturnValue = .success(())
        
        switch invites {
        case .rooms:
            clientProxy.roomForIdentifierClosure = { roomID in .invited(InvitedRoomProxyMock(.init(id: roomID))) }
        case .spaces:
            clientProxy.roomForIdentifierClosure = { spaceID in .invited(InvitedRoomProxyMock(.init(id: spaceID, isSpace: true))) }
            
            let spaceServiceProxy = SpaceServiceProxyMock(.init())
            spaceServiceProxy.spaceRoomListSpaceIDClosure = { spaceID in
                .success(SpaceRoomListProxyMock(.init(spaceServiceRoom: SpaceServiceRoom.mock(id: spaceID, isSpace: true))))
            }
            clientProxy.spaceService = spaceServiceProxy
        case nil:
            break
        }
        
        notificationService = NotificationServiceMock(.init())
        identityService = HomeScreenIdentityServiceStub(status: identityServiceStatus)
        notificationCenter = NotificationCenter()
        userIndicatorController = UserIndicatorControllerMock()
        let userSession = UserSessionMock(.init(clientProxy: clientProxy, userSettings: userSettings, notificationService: notificationService))
        if let securityStatePublisher {
            userSession.sessionSecurityStatePublisher = securityStatePublisher
        }
        
        let sessionDetails = [UserSessionDetails(userSession: userSession)] + otherAccountUserIDs.map { UserSessionDetails(userID: $0) }
        
        viewModel = HomeScreenViewModel(userSession: userSession,
                                        availableSessionsPublisher: .init(sessionDetails),
                                        selectedRoomPublisher: CurrentValueSubject<String?, Never>(nil).asCurrentValuePublisher(),
                                        analyticsService: AnalyticsServiceMock(.init()),
                                        bugReportService: BugReportServiceMock(.init()),
                                        userIndicatorController: userIndicatorController,
                                        identityServiceClient: identityService,
                                        notificationCenter: notificationCenter,
                                        securityStatusRetryDelay: securityStatusRetryDelay)
    }
}

@MainActor
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

@MainActor
extension HomeScreenViewModelAction: @MainActor @retroactive Equatable {
    public static func == (lhs: HomeScreenViewModelAction, rhs: HomeScreenViewModelAction) -> Bool {
        switch (lhs, rhs) {
        case (.presentRoom(let lhsID), .presentRoom(let rhsID)):
            lhsID == rhsID
        case (.presentRoomDetails(let lhsID), .presentRoomDetails(let rhsID)):
            lhsID == rhsID
        case (.presentReportRoom(let lhsID), .presentReportRoom(let rhsID)):
            lhsID == rhsID
        case (.presentDeclineAndBlock(let lhsUserID, let lhsRoomID), .presentDeclineAndBlock(let rhsUserID, let rhsRoomID)):
            lhsUserID == rhsUserID && lhsRoomID == rhsRoomID
        case (.presentSpace(let lhsSpaceRoomListProxy), .presentSpace(let rhsSpaceRoomListProxy)):
            lhsSpaceRoomListProxy.id == rhsSpaceRoomListProxy.id
        case (.roomLeft(let lhsID), .roomLeft(let rhsID)):
            lhsID == rhsID
        case (.transferOwnership(let lhsID), .transferOwnership(let rhsID)):
            lhsID == rhsID
        case (.presentSecureBackupSettings, .presentSecureBackupSettings):
            true
        case (.presentRecoveryKeyScreen, .presentRecoveryKeyScreen):
            true
        case (.presentEncryptionResetScreen, .presentEncryptionResetScreen):
            true
        case (.presentSettingsScreen, .presentSettingsScreen):
            true
        case (.presentFeedbackScreen, .presentFeedbackScreen):
            true
        case (.presentStartChatScreen, .presentStartChatScreen):
            true
        case (.logout, .logout):
            true
        default:
            false
        }
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
