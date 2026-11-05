//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AnalyticsEvents
import Combine
import MatrixRustSDK
import SwiftUI

typealias HomeScreenViewModelType = StateStoreViewModel<HomeScreenViewState, HomeScreenViewAction>

class HomeScreenViewModel: HomeScreenViewModelType, HomeScreenViewModelProtocol {
    private let userSession: UserSessionProtocol
    private let availableSessionsPublisher: CurrentValuePublisher<[UserSessionDetails], Never>
    private let spaceFilterSubject: CurrentValueSubject<SpaceServiceFilter?, Never>
    private let analyticsService: AnalyticsServiceProtocol
    private let bugReportService: BugReportServiceProtocol
    private let userSettings: UserSettings
    private let userIndicatorController: UserIndicatorControllerProtocol
    private let identityServiceClient: IdentityServiceClientProtocol?
    
    /// GUA FORK: re-reads the account's security report while the app stays in the foreground, so a
    /// recovery started while this device sits open still reaches its owner.
    private var accountRecoveryRefreshTask: Task<Void, Never>?
    private static let accountRecoveryRefreshInterval: Duration = .seconds(15 * 60)
    /// Reads a moment after the recovery's own times, so the server has passed them too.
    private static let accountRecoveryMomentSlack: Duration = .seconds(1)
    /// GUA FORK: the one early re-read that follows a failed read while the app is in the foreground.
    private var securityStatusRetryTask: Task<Void, Never>?
    private let securityStatusRetryDelay: Duration
    /// GUA FORK: reads of the security report overlap (session start, foreground, timer, cancel), and
    /// a slow one can come back after a newer one or after a cancel. Each read is numbered when it
    /// starts, and its result is dropped once a later read or a cancel has already set the banner.
    private var securityStatusReadsStarted = 0
    private var securityStatusReadsSuperseded = 0
    
    private let roomSummaryProvider: RoomSummaryProviderProtocol?
    
    private var actionsSubject: PassthroughSubject<HomeScreenViewModelAction, Never> = .init()
    var actions: AnyPublisher<HomeScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    // swiftlint:disable:next function_body_length
    init(userSession: UserSessionProtocol,
         availableSessionsPublisher: CurrentValuePublisher<[UserSessionDetails], Never>,
         selectedRoomPublisher: CurrentValuePublisher<String?, Never>,
         analyticsService: AnalyticsServiceProtocol,
         bugReportService: BugReportServiceProtocol,
         userIndicatorController: UserIndicatorControllerProtocol,
         identityServiceClient: IdentityServiceClientProtocol? = nil,
         notificationCenter: NotificationCenter = .default,
         securityStatusRetryDelay: Duration = .seconds(30)) {
        self.userSession = userSession
        self.availableSessionsPublisher = availableSessionsPublisher
        self.analyticsService = analyticsService
        self.bugReportService = bugReportService
        userSettings = userSession.userSettings
        self.userIndicatorController = userIndicatorController
        self.identityServiceClient = identityServiceClient ?? IdentityServiceClient()
        self.securityStatusRetryDelay = securityStatusRetryDelay
        
        spaceFilterSubject = CurrentValueSubject<SpaceServiceFilter?, Never>(nil)
        
        roomSummaryProvider = userSession.clientProxy.roomSummaryProvider
        
        super.init(initialViewState: .init(userProfile: userSession.clientProxy.userProfilePublisher.value,
                                           bindings: .init(filtersState: .init(userSettings: userSession.userSettings))),
                   mediaProvider: userSession.mediaProvider)
        
        if userSettings.app.globalSearchEnabled {
            state.isRoomListSearchEnabled = false
        }
        
        userSession.clientProxy.userProfilePublisher
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.state.userProfile, on: self)
            .store(in: &cancellables)
        
        userSession.sessionSecurityStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] securityState in
                guard let self else { return }
                
                switch securityState.recoveryState {
                // GUA FORK: both broken states get the same banner, the one that finishes setup
                // silently. Upstream sends .disabled to a "set up recovery" banner whose flow
                // hands the user a recovery key to write down, and .disabled is exactly what an
                // identity reset leaves behind, so that was the second half of the reset dead end.
                case .disabled, .incomplete:
                    if !state.securityBannerMode.isDismissed {
                        state.securityBannerMode = .show(.recoveryOutOfSync)
                    }
                default:
                    state.securityBannerMode = .none
                }
            }
            .store(in: &cancellables)
        
        // GUA FORK: the banner reports the background provisioning as work in progress.
        //
        // After a reset, key storage is provisioned behind this screen. Until it lands the recovery
        // state is legitimately still unhealthy, so the banner is still up -- and it used to look
        // exactly like an untouched "Finish setup" call to action, so people pressed it, and the
        // press looked like the thing that fixed the account. It was not; it just arrived after the
        // work had finished. Showing the work is the difference between those two readings.
        userSession.clientProxy.secureBackupController.isProvisioningKeyStorage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isProvisioning in
                guard let self else { return }
                // Never clears the tap-driven flag: finishEncryptionSetup owns that one and clears
                // it in its own defer.
                if isProvisioning {
                    state.isFinishingEncryptionSetup = true
                } else if !state.isRepairingEncryptionSetupFromTap {
                    state.isFinishingEncryptionSetup = false
                }
            }
            .store(in: &cancellables)

        userSession.sessionSecurityStatePublisher
            .receive(on: DispatchQueue.main)
            .filter { state in
                state.verificationState != .unknown
                    && state.recoveryState != .settingUp
                    && state.recoveryState != .unknown
            }
            .sink { [weak self] state in
                guard let self else { return }
                
                self.analyticsService.updateUserProperties(AnalyticsEvent.newVerificationStateUserProperty(verificationState: state.verificationState, recoveryState: state.recoveryState))
                self.analyticsService.trackSessionSecurityState(state)
            }
            .store(in: &cancellables)
        
        // GUA FORK: the Chats space filter follows the Spaces switch.
        userSession.clientProxy.spaceService.spaceFilterPublisher
            .combineLatest(userSettings.app.spacesEnabledPublisher)
            .map { filters, spacesEnabled in spacesEnabled ? filters : [] }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] filters in
                guard let self else { return }
                
                state.shouldShowSpaceFilters = !filters.isEmpty
                
                if let selectedSpaceFilter = spaceFilterSubject.value,
                   !filters.contains(selectedSpaceFilter) {
                    // Clear the spaces filter if the space has been left.
                    spaceFilterSubject.send(nil)
                }
            }
            .store(in: &cancellables)
        
        selectedRoomPublisher
            .weakAssign(to: \.state.selectedRoomID, on: self)
            .store(in: &cancellables)
        
        userSettings.account.showAllRoomListActivityPublisher
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.updateRooms()
            }
            .store(in: &cancellables)
        
        userSettings.account.seenInvitesPublisher
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.updateRooms()
            }
            .store(in: &cancellables)
        
        userSettings.app.hasSeenNewSoundBannerPublisher
            .sink { [weak self] hasSeenNewSoundBanner in
                self?.state.shouldShowNewSoundBanner = !hasSeenNewSoundBanner
            }
            .store(in: &cancellables)
        
        userSession.clientProxy.hideInviteAvatarsPublisher
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.state.hideInviteAvatars, on: self)
            .store(in: &cancellables)
        
        spaceFilterSubject
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.state.selectedSpaceFilter, on: self)
            .store(in: &cancellables)
        
        bugReportService.lastCrashEventIDSubject
            .compactMap { $0 }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.presentCrashedLastRunAlert()
            }
            .store(in: &cancellables)
        
        Task {
            state.reportRoomEnabled = await userSession.clientProxy.isReportRoomSupported
        }
        
        let isSearchFieldFocused = context.$viewState.map(\.bindings.isSearchFieldFocused)
        let searchQuery = context.$viewState.map(\.bindings.searchQuery)
        let activeFilters = context.$viewState.map(\.bindings.filtersState.activeFilters)
        isSearchFieldFocused
            .combineLatest(searchQuery, activeFilters, spaceFilterSubject)
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] isSearchFieldFocused, _, _, _ in
                guard let self else { return }
                // isSearchFieldFocused` is sometimes turning to true after cancelling the search. So to be extra sure we are updating the values correctly we read them directly in the next run loop, and we add a small delay if the value has changed
                let delay = isSearchFieldFocused == self.context.viewState.bindings.isSearchFieldFocused ? 0.0 : 0.05
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self.updateFilter()
                }
            }
            .store(in: &cancellables)
        
        setupRoomListSubscriptions()
        
        updateRooms()
        
        if let roomSummaryProvider {
            updateRoomListMode(with: roomSummaryProvider.statePublisher.value,
                               hasRooms: !roomSummaryProvider.roomListPublisher.value.isEmpty)
        }
        
        // Fall back to the skeletons if the cached rooms take too long to publish.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, state.roomListMode == .awaitingCachedRooms else { return }
            state.roomListMode = .skeletons
        }
        
        setupSecurityStatusRefresh(notificationCenter: notificationCenter)
    }
    
    // MARK: - Public
    
    override func process(viewAction: HomeScreenViewAction) {
        switch viewAction {
        case .selectRoom(let roomIdentifier):
            actionsSubject.send(.presentRoom(roomIdentifier: roomIdentifier))
        case .detachRoom(let roomIdentifier):
            actionsSubject.send(.detachRoom(roomIdentifier: roomIdentifier))
        case .showRoomDetails(let roomIdentifier):
            actionsSubject.send(.presentRoomDetails(roomIdentifier: roomIdentifier))
        case .leaveRoom(let roomIdentifier):
            startLeaveRoomProcess(roomID: roomIdentifier)
        case .confirmLeaveRoom(let roomIdentifier):
            Task { await leaveRoom(roomID: roomIdentifier) }
        case .reportRoom(let roomIdentifier):
            actionsSubject.send(.presentReportRoom(roomIdentifier: roomIdentifier))
        case .showSettings:
            actionsSubject.send(.presentSettingsScreen)
        case .setupRecovery:
            actionsSubject.send(.presentSecureBackupSettings)
        case .confirmRecoveryKey:
            // GUA FORK: the banner's single button. Try everything non-destructive first and
            // only surface the reset, with its warning, if one is genuinely required. Most
            // devices repair silently here and the user never learns a reset existed.
            //
            // The flag is set here, synchronously on the main actor, so the spinner lands in the
            // same frame as the tap rather than after the first await. It doubles as the re-entry
            // guard, and finishEncryptionSetup clears it on every outcome.
            guard !state.isFinishingEncryptionSetup else { return }
            state.isRepairingEncryptionSetupFromTap = true
            state.isFinishingEncryptionSetup = true
            Task { await finishEncryptionSetup() }
        case .resetEncryption:
            actionsSubject.send(.presentEncryptionResetScreen)
        case .skipRecoveryKeyConfirmation:
            state.securityBannerMode = .dismissed
        case .setUpPinReminder:
            state.pinSetupReminderVisible = false
            actionsSubject.send(.presentTwoStepVerificationSetup)
        case .dismissPinReminder:
            state.pinSetupReminderVisible = false
            // Snooze for a week so we don't badger the user.
            userSettings.app.pinSetupReminderSnoozedUntil = Date().addingTimeInterval(7 * 24 * 60 * 60)
        case .cancelAccountRecovery:
            state.bindings.alertInfo = AlertInfo(id: UUID(),
                                                 title: L10n.screenAccountRecoveryCancelConfirmTitle,
                                                 message: L10n.screenAccountRecoveryCancelConfirmMessage,
                                                 primaryButton: .init(title: L10n.actionGoBack, role: .cancel, action: nil),
                                                 secondaryButton: .init(title: L10n.screenAccountRecoveryBannerAction, role: .destructive) { [weak self] in
                                                     Task { await self?.cancelAccountRecovery() }
                                                 })
        case .dismissNewSoundBanner:
            userSettings.app.hasSeenNewSoundBanner = true
        case .screenAppeared:
            // Use a task otherwise the presentation isn't animated.
            Task { presentMultiAccountAnnouncementIfNeeded() }
        case .multiAccountAnnouncementAppeared:
            MXLog.info("The multi-account announcement has been seen.")
            userSettings.app.hasSeenMultiAccountAnnouncement = true
        case .dismissMultiAccountAnnouncement, .addAccount: // There is no add account flow to start yet.
            state.bindings.isPresentingMultiAccountAnnouncement = false
        case .updateVisibleItemRange(let range):
            roomSummaryProvider?.updateVisibleRange(range)
        case .startChat:
            actionsSubject.send(.presentStartChatScreen)
        case .spaceFilters:
            if spaceFilterSubject.value != nil {
                spaceFilterSubject.send(nil)
            } else {
                state.bindings.spaceFiltersViewModel = ChatsSpaceFiltersScreenViewModel(spaceService: userSession.clientProxy.spaceService,
                                                                                        mediaProvider: userSession.mediaProvider)
                
                state.bindings.spaceFiltersViewModel?.actionsPublisher.sink { [weak self] action in
                    guard let self else { return }
                    
                    switch action {
                    case .confirm(let spaceServiceFilter):
                        spaceFilterSubject.send(spaceServiceFilter)
                        state.bindings.spaceFiltersViewModel = nil
                    case .cancel:
                        state.bindings.spaceFiltersViewModel = nil
                    }
                }
                .store(in: &cancellables)
            }
        case .markRoomAsUnread(let roomIdentifier):
            Task {
                guard case let .joined(roomProxy) = await userSession.clientProxy.roomForIdentifier(roomIdentifier) else {
                    MXLog.error("Failed retrieving room for identifier: \(roomIdentifier)")
                    return
                }
                
                switch await roomProxy.flagAsUnread(true) {
                case .success:
                    analyticsService.trackInteraction(name: .MobileRoomListRoomContextMenuUnreadToggle)
                case .failure(let error):
                    MXLog.error("Failed marking room \(roomIdentifier) as unread with error: \(error)")
                }
            }
        case .markRoomAsRead(let roomIdentifier):
            Task {
                guard case let .joined(roomProxy) = await userSession.clientProxy.roomForIdentifier(roomIdentifier) else {
                    MXLog.error("Failed retrieving room for identifier: \(roomIdentifier)")
                    return
                }
                
                switch await roomProxy.flagAsUnread(false) {
                case .success:
                    analyticsService.trackInteraction(name: .MobileRoomListRoomContextMenuUnreadToggle)
                    
                    if case .failure(let error) = await roomProxy.markAsRead(receiptType: userSettings.account.sharePresence ? .read : .readPrivate) {
                        MXLog.error("Failed marking room \(roomIdentifier) as read with error: \(error)")
                    }
                case .failure(let error):
                    MXLog.error("Failed flagging room \(roomIdentifier) as read with error: \(error)")
                }
            }
        case .markRoomAsFavourite(let roomIdentifier, let isFavourite):
            Task {
                await markRoomAsFavourite(roomIdentifier, isFavourite: isFavourite)
            }
        case .acceptInvite(let roomIdentifier):
            Task {
                await acceptInvite(roomID: roomIdentifier)
            }
        case .declineInvite(let roomIdentifier):
            Task { await showDeclineInviteConfirmationAlert(roomID: roomIdentifier) }
        }
    }
    
    // perphery: ignore - used in release mode
    func presentCrashedLastRunAlert() {
        // Delay setting the alert otherwise it automatically gets dismissed. Same as the force logout one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            state.bindings.alertInfo = AlertInfo(id: UUID(),
                                                 title: L10n.crashDetectionDialogContent(InfoPlistReader.main.bundleDisplayName),
                                                 primaryButton: .init(title: L10n.actionNo, action: nil),
                                                 secondaryButton: .init(title: L10n.actionYes) { [weak self] in
                                                     self?.actionsSubject.send(.presentFeedbackScreen)
                                                 })
        }
    }
    
    /// GUA FORK: completes encryption setup for a device that could not do it on its own.
    ///
    /// Staged on purpose. The repair that needs no reset is attempted first and silently, because
    /// for most devices it works and a warning about losing messages would be both alarming and
    /// untrue. The destructive confirmation is only shown once we know a reset is actually
    /// required, which is the only case where anything can be lost.
    private func finishEncryptionSetup() async {
        // Clears on every path out, so the button can never latch.
        defer {
            state.isRepairingEncryptionSetupFromTap = false
            state.isFinishingEncryptionSetup = false
        }

        let secureBackupController = userSession.clientProxy.secureBackupController
        switch await secureBackupController.repairWithoutReset() {
        case .repaired:
            MXLog.info("GUA-KEYSTORE: finished encryption setup without a reset.")
        case .notYet:
            // The client cannot read its own state yet, so there is nothing to repair and nothing
            // to warn about. Leave the banner up rather than sending anyone to a reset.
            MXLog.info("GUA-KEYSTORE: encryption state not readable yet, leaving the banner.")
        case .resetRequired:
            MXLog.info("GUA-KEYSTORE: setup needs a reset, asking first.")
            actionsSubject.send(.presentEncryptionResetScreen)
        case .identityIncompleteAfterReset:
            MXLog.info("GUA-KEYSTORE: the account is incomplete after a reset, leaving the banner.")
        }
    }

    // MARK: - Private
    
    private func updateFilter() {
        if state.shouldHideRoomList {
            roomSummaryProvider?.setFilter(.excludeAll)
        } else {
            if state.bindings.isSearchFieldFocused {
                roomSummaryProvider?.setFilter(.search(query: state.bindings.searchQuery))
            } else {
                if let spaceFilter = spaceFilterSubject.value {
                    roomSummaryProvider?.setFilter(.rooms(roomsIDs: spaceFilter.descendants,
                                                          filters: state.bindings.filtersState.activeFilters.set))
                } else {
                    roomSummaryProvider?.setFilter(.all(filters: state.bindings.filtersState.activeFilters.set))
                }
            }
        }
    }
    
    private func setupRoomListSubscriptions() {
        guard let roomSummaryProvider else {
            MXLog.error("Room summary provider unavailable")
            return
        }
        
        // Combined so that the mode and the rooms are always updated from the same pair of
        // values: the state can report loaded before the first summaries have published and
        // flipping to .rooms then would flash an empty list.
        roomSummaryProvider.statePublisher
            .combineLatest(roomSummaryProvider.roomListPublisher)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state, rooms in
                guard let self else { return }
                
                updateRooms()
                updateRoomListMode(with: state, hasRooms: !rooms.isEmpty)
            }
            .store(in: &cancellables)
    }
    
    private func updateRoomListMode(with roomSummaryProviderState: RoomSummaryProviderState, hasRooms: Bool) {
        let isFiltering = state.bindings.filtersState.isFiltering || state.selectedSpaceFilter != nil || state.bindings.isSearchFieldFocused
        
        let roomListMode: HomeScreenRoomListMode = if !roomSummaryProviderState.isLoaded {
            .skeletons // Still loading.
        } else if roomSummaryProviderState.totalNumberOfRooms == 0 {
            .empty // Loaded, there are no rooms at all.
        } else if hasRooms || isFiltering {
            .rooms // Loaded and the summaries have published (or filtered down to nothing).
        } else if state.roomListMode == .skeletons || state.roomListMode == .awaitingCachedRooms {
            state.roomListMode // Loaded but nothing published yet, flipping to .rooms would flash an empty list.
        } else {
            .rooms
        }
        
        guard roomListMode != state.roomListMode else {
            return
        }
        
        if roomListMode == .rooms, state.roomListMode == .skeletons || state.roomListMode == .awaitingCachedRooms {
            analyticsService.signpost.finishTransaction(.cachedRoomList)
        }
        
        state.roomListMode = roomListMode
        
        MXLog.info("Received room summary provider update, setting view room list mode to \"\(state.roomListMode)\"")
        // Delay user profile detail loading until after the initial room list loads
        if roomListMode == .rooms {
            Task {
                await self.userSession.clientProxy.loadUserProfileIfNeeded()
            }
        }
    }
    
    private func updateRooms() {
        guard let roomSummaryProvider else {
            MXLog.error("Room summary provider unavailable")
            return
        }
        
        var rooms = [HomeScreenRoom]()
        let seenInvites = userSettings.account.seenInvites
        
        for summary in roomSummaryProvider.roomListPublisher.value {
            // GUA FORK: hide stray empty "orphan" DMs (no members, no name, no messages) so a
            // half-created or never-joined room doesn't clutter the chat list.
            guard !summary.isEmptyOrphanRoom else { continue }

            let room = HomeScreenRoom(summary: summary,
                                      showAllActivity: userSettings.account.showAllRoomListActivity,
                                      seenInvites: seenInvites)
            rooms.append(room)
        }
        
        state.rooms = rooms
    }
    
    private func markRoomAsFavourite(_ roomID: String, isFavourite: Bool) async {
        guard case let .joined(roomProxy) = await userSession.clientProxy.roomForIdentifier(roomID) else {
            MXLog.error("Failed retrieving room for identifier: \(roomID)")
            return
        }
        
        switch await roomProxy.flagAsFavourite(isFavourite) {
        case .success:
            analyticsService.trackInteraction(name: .MobileRoomListRoomContextMenuFavouriteToggle)
        case .failure(let error):
            MXLog.error("Failed marking room \(roomID) as favourite: \(isFavourite) with error: \(error)")
        }
    }
    
    private static let leaveRoomLoadingID = "LeaveRoomLoading"
    
    private func startLeaveRoomProcess(roomID: String) {
        Task { [self] in
            defer {
                userIndicatorController.retractIndicatorWithId(Self.leaveRoomLoadingID)
            }
            userIndicatorController.submitIndicator(UserIndicator(id: Self.leaveRoomLoadingID, type: .modal, title: L10n.commonLoading, persistent: true))
            
            guard case let .joined(roomProxy) = await userSession.clientProxy.roomForIdentifier(roomID) else {
                state.bindings.alertInfo = AlertInfo(id: UUID(), title: L10n.errorUnknown)
                return
            }
            
            guard roomProxy.infoPublisher.value.joinedMembersCount > 1 else {
                state.bindings.leaveRoomAlertItem = LeaveRoomAlertItem(roomID: roomID,
                                                                       isDM: roomProxy.infoPublisher.value.isDM,
                                                                       state: roomProxy.infoPublisher.value.isPrivate ?? true ? .empty : .public)
                return
            }
            
            if !roomProxy.infoPublisher.value.isDM {
                if case let .success(ownMember) = await roomProxy.getMember(userID: roomProxy.ownUserID),
                   ownMember.role.isOwner {
                    await roomProxy.updateMembers()
                    var isLastOwner = true
                    for member in roomProxy.membersPublisher.value where member.userID != roomProxy.ownUserID && member.membership == .join {
                        if member.role.isOwner {
                            isLastOwner = false
                            break
                        }
                    }
                    
                    if isLastOwner {
                        state.bindings.alertInfo = .init(id: UUID(),
                                                         title: L10n.leaveRoomAlertSelectNewOwnerTitle,
                                                         message: L10n.leaveRoomAlertSelectNewOwnerSubtitle,
                                                         primaryButton: .init(title: L10n.actionCancel, role: .cancel, action: nil),
                                                         secondaryButton: .init(title: L10n.leaveRoomAlertSelectNewOwnerAction, role: .destructive) { [weak self] in
                                                             self?.actionsSubject.send(.transferOwnership(roomIdentifier: roomID))
                                                         })
                        return
                    }
                }
            }
            
            state.bindings.leaveRoomAlertItem = LeaveRoomAlertItem(roomID: roomID, isDM: roomProxy.infoPublisher.value.isDM, state: roomProxy.infoPublisher.value.isPrivate ?? true ? .private : .public)
        }
    }
    
    private func leaveRoom(roomID: String) async {
        defer {
            userIndicatorController.retractIndicatorWithId(Self.leaveRoomLoadingID)
        }
        userIndicatorController.submitIndicator(UserIndicator(id: Self.leaveRoomLoadingID, type: .modal, title: L10n.commonLeavingRoom, persistent: true))
        
        guard case let .joined(roomProxy) = await userSession.clientProxy.roomForIdentifier(roomID),
              case .success = await roomProxy.leaveRoom() else {
            state.bindings.alertInfo = AlertInfo(id: UUID(), title: L10n.errorUnknown)
            return
        }
        
        userIndicatorController.submitIndicator(UserIndicator(id: UUID().uuidString,
                                                              type: .toast,
                                                              title: L10n.commonCurrentUserLeftRoom,
                                                              icon: \.check))
        actionsSubject.send(.roomLeft(roomIdentifier: roomID))
    }
    
    // MARK: Multi-account announcement
    
    private func presentMultiAccountAnnouncementIfNeeded() {
        // Never announce it to someone who already uses several accounts, even once they've removed some.
        if availableSessionsPublisher.value.count > 1, !userSettings.app.hasSeenMultiAccountAnnouncement {
            MXLog.info("Several accounts are signed in, marking the multi-account announcement as seen.")
            userSettings.app.hasSeenMultiAccountAnnouncement = true
        }
        
        // An unverified session gets the identity confirmation cover first, the room list appears again once it's dismissed.
        guard userSettings.app.multiAccountEnabled,
              !userSettings.app.hasSeenMultiAccountAnnouncement,
              userSession.sessionSecurityStatePublisher.value.verificationState == .verified,
              !state.bindings.isPresentingMultiAccountAnnouncement else {
            return
        }
        
        MXLog.info("Presenting the multi-account announcement.")
        state.bindings.isPresentingMultiAccountAnnouncement = true
    }
    
    // MARK: Invites
    
    private func acceptInvite(roomID: String) async {
        defer {
            userIndicatorController.retractIndicatorWithId(roomID)
        }
        
        userIndicatorController.submitIndicator(UserIndicator(id: roomID, type: .modal, title: L10n.commonLoading, persistent: true))
        
        guard case let .invited(roomProxy) = await userSession.clientProxy.roomForIdentifier(roomID) else {
            displayError()
            return
        }
        
        // GUA FORK: with Spaces off, space invites are accepted on the join screen, which turns Spaces on first.
        if roomProxy.info.isSpace, !userSettings.app.spacesEnabled {
            actionsSubject.send(.presentRoom(roomIdentifier: roomID))
            return
        }
        
        switch await userSession.clientProxy.joinRoom(roomID, via: []) {
        case .success:
            await finishAcceptInvite(roomProxy: roomProxy)
        case .failure(let error):
            switch error {
            case .invalidInvite:
                displayError(title: L10n.dialogTitleError, message: L10n.errorInvalidInvite)
            default:
                displayError()
            }
        }
    }
    
    private func finishAcceptInvite(roomProxy: InvitedRoomProxyProtocol) async {
        if roomProxy.info.isSpace {
            let spaceService = userSession.clientProxy.spaceService
            
            switch await spaceService.spaceRoomList(spaceID: roomProxy.id) {
            case .success(let spaceRoomListProxy):
                actionsSubject.send(.presentSpace(spaceRoomListProxy))
            case .failure(let error):
                MXLog.error("Failed to get the space room list after accepting invite: \(error)")
                displayError()
                return
            }
        } else {
            actionsSubject.send(.presentRoom(roomIdentifier: roomProxy.id))
        }
        
        analyticsService.trackJoinedRoom(isDM: roomProxy.info.isDirect,
                                         isSpace: roomProxy.info.isSpace,
                                         activeMemberCount: UInt(roomProxy.info.activeMembersCount))
        userSettings.account.seenInvites.remove(roomProxy.id)
    }
    
    private func showDeclineInviteConfirmationAlert(roomID: String) async {
        guard let room = state.rooms.first(where: { $0.id == roomID }) else {
            displayError()
            return
        }
        
        let roomPlaceholder = room.isDirect ? (room.inviter?.displayName ?? room.name) : room.name
        let title = room.isDirect ? L10n.screenInvitesDeclineDirectChatTitle : L10n.screenInvitesDeclineChatTitle
        let message = room.isDirect ? L10n.screenInvitesDeclineDirectChatMessage(roomPlaceholder) : L10n.screenInvitesDeclineChatMessage(roomPlaceholder)
        
        if await userSession.clientProxy.isReportRoomSupported, let userID = room.inviter?.id {
            state.bindings.alertInfo = .init(id: UUID(),
                                             title: title,
                                             message: message,
                                             primaryButton: .init(title: L10n.actionCancel, role: .cancel, action: nil),
                                             secondaryButton: .init(title: L10n.actionDeclineAndBlock, role: .destructive) { [weak self] in self?.declineAndBlockInvite(userID: userID, roomID: roomID) },
                                             verticalButtons: [.init(title: L10n.actionDecline) { [weak self] in Task { await self?.declineInvite(roomID: room.id) } }])
        } else {
            state.bindings.alertInfo = .init(id: UUID(),
                                             title: title,
                                             message: message,
                                             primaryButton: .init(title: L10n.actionCancel, role: .cancel, action: nil),
                                             secondaryButton: .init(title: L10n.actionDecline, role: .destructive) { [weak self] in Task { await self?.declineInvite(roomID: room.id) } })
        }
    }
    
    private func declineAndBlockInvite(userID: String, roomID: String) {
        actionsSubject.send(.presentDeclineAndBlock(userID: userID, roomID: roomID))
    }
    
    private func declineInvite(roomID: String) async {
        defer {
            userIndicatorController.retractIndicatorWithId(roomID)
        }
        
        userIndicatorController.submitIndicator(UserIndicator(id: roomID, type: .modal, title: L10n.commonLoading, persistent: true))
        
        guard case let .invited(roomProxy) = await userSession.clientProxy.roomForIdentifier(roomID) else {
            displayError()
            return
        }
        
        let result = await roomProxy.rejectInvitation()
        
        switch result {
        case .success:
            userSession.notificationService.removeDeliveredMessageNotifications(for: roomID) // Normally handled by the room flow, but that's never presented in this case.
            userSettings.account.seenInvites.remove(roomID)
        case .failure:
            displayError()
        }
    }
    
    private func displayError(title: String? = nil, message: String? = nil) {
        state.bindings.alertInfo = .init(id: UUID(),
                                         title: title ?? L10n.commonError,
                                         message: message ?? L10n.errorUnknown)
    }

    /// GUA FORK: reads the account's security report and applies it to the banners built from it.
    ///
    /// The PIN reminder is a one-shot at session start. It asks for two-step verification, so it is
    /// shown when the account holds neither factor that counts as one, not when it merely has no
    /// PIN: somebody who signs in with a passkey has already done what the banner is asking for.
    ///
    /// The account recovery banner is refreshed on every read and ignores the reminder's snooze,
    /// because it is a warning rather than a nudge.
    ///
    /// A report that cannot be read changes nothing. Nudging an account that may already be
    /// protected is the wrong way to be wrong, and so is hiding a recovery because of a bad network.
    /// It is read once more shortly after, rather than at the next tick of the timer.
    private func refreshSecurityStatus(updatingPinReminder: Bool) async {
        guard let identityServiceClient else { return }
        guard let accessToken = userSession.clientProxy.accessToken else {
            scheduleSecurityStatusRetry()
            return
        }
        securityStatusReadsStarted += 1
        let read = securityStatusReadsStarted
        let status: AccountSecurityStatus
        do {
            status = try await identityServiceClient.securityStatus(accessToken: accessToken)
        } catch {
            MXLog.warning("Could not fetch the account's security status for the home screen: \(error)")
            // A read cut short by its own timer or retry being cancelled did not fail.
            if !Task.isCancelled {
                scheduleSecurityStatusRetry()
            }
            return
        }
        cancelSecurityStatusRetry()

        if read > securityStatusReadsSuperseded {
            securityStatusReadsSuperseded = read
            let previousBanner = state.accountRecoveryBanner
            state.accountRecoveryBanner = status.pendingAccountRecovery
            // The timer's wait was worked out from the banner it saw; a different one may need a sooner read.
            if state.accountRecoveryBanner != previousBanner, accountRecoveryRefreshTask != nil {
                startAccountRecoveryRefreshTimer()
            }
        }

        guard updatingPinReminder else { return }
        if let snoozedUntil = userSettings.app.pinSetupReminderSnoozedUntil, snoozedUntil > Date() {
            return
        }
        state.pinSetupReminderVisible = !status.holdsStrongFactor
    }

    /// GUA FORK: the security report is read at session start, again whenever the app comes back to
    /// the foreground, and on a timer while it stays there.
    private func setupSecurityStatusRefresh(notificationCenter: NotificationCenter) {
        notificationCenter.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.refreshSecurityStatus(updatingPinReminder: false) }
                startAccountRecoveryRefreshTimer()
            }
            .store(in: &cancellables)

        notificationCenter.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                self?.accountRecoveryRefreshTask?.cancel()
                self?.accountRecoveryRefreshTask = nil
                self?.cancelSecurityStatusRetry()
            }
            .store(in: &cancellables)

        Task { await refreshSecurityStatus(updatingPinReminder: true) }
        startAccountRecoveryRefreshTimer()
    }

    /// Restarting the timer replaces the wait in progress with one worked out from the banner shown now.
    private func startAccountRecoveryRefreshTimer() {
        accountRecoveryRefreshTask?.cancel()
        accountRecoveryRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.nextAccountRecoveryReadDelay() else { return }
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                await refreshSecurityStatus(updatingPinReminder: false)
            }
        }
    }

    private func nextAccountRecoveryReadDelay() -> Duration {
        Self.accountRecoveryReadDelay(for: state.accountRecoveryBanner, now: .now)
    }

    /// GUA FORK: how long the timer waits before the next read: the regular interval, or less when the
    /// recovery on the banner becomes finishable or runs out before then, so the banner switches to
    /// "can be finished now" and comes down on time. Moments already past are ignored, so a server that
    /// still reports the recovery after its expiry on this device's clock falls back to the interval.
    /// Matches the Android client.
    static func accountRecoveryReadDelay(for recovery: PendingAccountRecovery?, now: Date) -> Duration {
        let nextMoment = [recovery?.completableAt, recovery?.expiresAt]
            .compactMap { $0 }
            .filter { $0 > now }
            .min()
        guard let nextMoment else { return accountRecoveryRefreshInterval }
        return min(accountRecoveryRefreshInterval, .seconds(nextMoment.timeIntervalSince(now)) + accountRecoveryMomentSlack)
    }

    /// GUA FORK: a failed read, such as a 401 for an access token that expired while the app was in
    /// the background and is refreshed on return, is followed by one early re-read. Failures while one
    /// is waiting or running do not add another, so retries neither stack nor chain: when the re-read
    /// fails too, the timer takes over again.
    private func scheduleSecurityStatusRetry() {
        // Only while in the foreground, where the timer runs: coming back reads the report anyway.
        guard securityStatusRetryTask == nil, accountRecoveryRefreshTask != nil else { return }
        securityStatusRetryTask = Task { [weak self, securityStatusRetryDelay] in
            try? await Task.sleep(for: securityStatusRetryDelay)
            guard !Task.isCancelled, let self else { return }
            await refreshSecurityStatus(updatingPinReminder: false)
            if !Task.isCancelled {
                securityStatusRetryTask = nil
            }
        }
    }

    private func cancelSecurityStatusRetry() {
        securityStatusRetryTask?.cancel()
        securityStatusRetryTask = nil
    }

    private static let cancelAccountRecoveryLoadingID = "CancelAccountRecoveryLoading"

    /// GUA FORK: the owner cancels a recovery from a signed-in device.
    ///
    /// The server answers 204 whether or not anything was pending, so after a success the banner is
    /// cleared and the report read again. Reads that started before the cancel are ignored when they
    /// come back, since they describe the account as it was. If the fresh read still shows a live
    /// recovery, the banner comes straight back and the owner is told the cancel did not take,
    /// rather than shown a toast that claims otherwise. A fresh read that fails leaves the banner
    /// cleared, trusting the server's answer to the cancel.
    private func cancelAccountRecovery() async {
        guard let identityServiceClient,
              let accessToken = userSession.clientProxy.accessToken else {
            displayError(message: L10n.screenAccountRecoveryCancelFailed)
            return
        }

        userIndicatorController.submitIndicator(UserIndicator(id: Self.cancelAccountRecoveryLoadingID,
                                                              type: .modal,
                                                              title: L10n.commonLoading,
                                                              persistent: true))
        do {
            try await identityServiceClient.cancelAccountRecovery(accessToken: accessToken)
        } catch {
            MXLog.error("Could not cancel the account recovery: \(error)")
            userIndicatorController.retractIndicatorWithId(Self.cancelAccountRecoveryLoadingID)
            displayError(message: L10n.screenAccountRecoveryCancelFailed)
            return
        }

        securityStatusReadsSuperseded = securityStatusReadsStarted
        state.accountRecoveryBanner = nil
        await refreshSecurityStatus(updatingPinReminder: false)
        userIndicatorController.retractIndicatorWithId(Self.cancelAccountRecoveryLoadingID)

        guard state.accountRecoveryBanner == nil else {
            MXLog.warning("The account recovery is still live after a successful cancel")
            displayError(message: L10n.screenAccountRecoveryCancelFailed)
            return
        }
        userIndicatorController.submitIndicator(UserIndicator(id: UUID().uuidString,
                                                              type: .toast,
                                                              title: L10n.screenAccountRecoveryCancelled,
                                                              icon: \.check))
    }
}
