//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

enum SettingsFlowCoordinatorAction {
    case dismiss
    case clearCache
    case runLogoutFlow
    /// Logout without a confirmation. The user forgot their PIN.
    case forceLogout
}

class SettingsFlowCoordinator: FlowCoordinatorProtocol {
    private let appLockService: AppLockServiceProtocol
    private let isInSecondaryWindow: Bool
    private let navigationStackCoordinator: NavigationStackCoordinator
    private let flowParameters: CommonFlowParameters
    
    private var userSettings: UserSettings {
        flowParameters.userSession.userSettings
    }
    
    // periphery:ignore - retaining purpose
    private var appLockSetupFlowCoordinator: AppLockSetupFlowCoordinator?
    private var bugReportFlowCoordinator: BugReportFlowCoordinator?
    // periphery:ignore - retaining purpose
    private var encryptionSettingsFlowCoordinator: EncryptionSettingsFlowCoordinator?
    // periphery:ignore - retaining purpose
    private var linkNewDeviceFlowCoordinator: LinkNewDeviceFlowCoordinator?
    
    private var cancellables = Set<AnyCancellable>()
    
    private let actionsSubject: PassthroughSubject<SettingsFlowCoordinatorAction, Never> = .init()
    var actions: AnyPublisher<SettingsFlowCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(appLockService: AppLockServiceProtocol,
         isInSecondaryWindow: Bool,
         navigationStackCoordinator: NavigationStackCoordinator,
         flowParameters: CommonFlowParameters) {
        self.appLockService = appLockService
        self.isInSecondaryWindow = isInSecondaryWindow
        self.navigationStackCoordinator = navigationStackCoordinator
        self.flowParameters = flowParameters
    }
    
    func start(animated: Bool) {
        fatalError("Unavailable")
    }
    
    func handleAppRoute(_ appRoute: AppRoute, animated: Bool) {
        MXLog.info("Handling app route: \(appRoute)")
        
        switch appRoute {
        case .settings:
            presentSettingsScreen(animated: animated)
        case .settingsTwoStepVerification:
            presentSettingsScreen(animated: animated)
            presentTwoStepVerification()
        case .chatBackupSettings:
            startEncryptionSettingsFlow()
        default:
            break
        }
    }
    
    func clearRoute(animated: Bool) {
        fatalError("Unavailable")
    }
    
    // MARK: - Private
    
    private func presentSettingsScreen(animated: Bool) {
        let settingsScreenCoordinator = SettingsScreenCoordinator(parameters: .init(userSession: flowParameters.userSession,
                                                                                    spacesSetting: flowParameters.spacesSetting,
                                                                                    isBugReportServiceEnabled: flowParameters.bugReportService.isEnabled,
                                                                                    isInSecondaryWindow: isInSecondaryWindow,
                                                                                    userIndicatorController: flowParameters.userIndicatorController))
        
        settingsScreenCoordinator.actions
            .sink { [weak self] action in
                guard let self else { return }
                
                switch action {
                case .dismiss:
                    actionsSubject.send(.dismiss)
                    
                case .userDetails:
                    presentUserDetailsEditScreen()
                case let .userStatusEmojiPicker(continuation):
                    presentEmojiPicker(emojiPickerContinuation: continuation)
                    
                case .addAccount:
                    break // Nothing to present until the add account flow exists.
                    
                case let .manageAccount(url):
                    presentAccountManagementURL(url)
                case .linkNewDevice:
                    startLinkNewDeviceFlow()
                case .notifications:
                    presentNotificationSettings()
                case .secureBackup:
                    startEncryptionSettingsFlow()
                case .moderationAndSafety:
                    presentModerationAndSafetySettings()
                case .bugReport:
                    bugReportFlowCoordinator = BugReportFlowCoordinator(parameters: .init(presentationMode: .push(navigationStackCoordinator),
                                                                                          userIndicatorController: flowParameters.userIndicatorController,
                                                                                          bugReportService: flowParameters.bugReportService,
                                                                                          userSession: flowParameters.userSession))
                    bugReportFlowCoordinator?.start()
                    
                case .logout:
                    actionsSubject.send(.runLogoutFlow)
                case .deactivateAccount:
                    presentDeactivateAccount()
                case .twoStepVerification:
                    presentTwoStepVerification()
                case .changePhoneNumber:
                    presentChangePhone()
                case .findFriends:
                    presentFindFriends()
                    
                case .mediaUploadQuality:
                    presentMediaUploadQualitySettings()
                case .appLock:
                    presentAppLockSetupFlow()
                case .locationSharing:
                    presentLocationSharingSettings()
                case .analytics:
                    presentAnalyticsScreen()
                case .labs:
                    presentLabs()
                case .about:
                    presentLegalInformationScreen()
                    
                case .developerOptions:
                    presentDeveloperOptions()
                }
            }
            .store(in: &cancellables)
        
        navigationStackCoordinator.setRootCoordinator(settingsScreenCoordinator, animated: animated)
    }
    
    private func presentLabs() {
        let coordinator = LabsScreenCoordinator(parameters: .init(userSettings: userSettings))
        coordinator.actions
            .sink { [weak self] action in
                switch action {
                case .clearCache:
                    self?.actionsSubject.send(.clearCache)
                }
            }
            .store(in: &cancellables)
        
        navigationStackCoordinator.push(coordinator)
    }
    
    private func startEncryptionSettingsFlow() {
        let coordinator = EncryptionSettingsFlowCoordinator(parameters: .init(userSession: flowParameters.userSession,
                                                                              userIndicatorController: flowParameters.userIndicatorController,
                                                                              navigationStackCoordinator: navigationStackCoordinator))
        coordinator.actionsPublisher.sink { [weak self] action in
            switch action {
            case .complete:
                // The flow coordinator tidies up the stack, no need to do anything.
                self?.encryptionSettingsFlowCoordinator = nil
            }
        }
        .store(in: &cancellables)
        
        encryptionSettingsFlowCoordinator = coordinator
        coordinator.start()
    }
    
    private func presentEmojiPicker(emojiPickerContinuation: EmojiPickerScreenContinuation) {
        let coordinator = EmojiPickerScreenCoordinator(parameters: .init(mode: .userStatus,
                                                                         selectedEmojis: [],
                                                                         emojiProvider: flowParameters.emojiProvider,
                                                                         continuation: emojiPickerContinuation))
        coordinator.actions
            .sink { [weak self] action in
                switch action {
                case .dismiss:
                    self?.navigationStackCoordinator.setSheetCoordinator(nil)
                }
            }
            .store(in: &cancellables)
        
        navigationStackCoordinator.setSheetCoordinator(coordinator)
    }
    
    private func presentUserDetailsEditScreen() {
        let coordinator = UserDetailsEditScreenCoordinator(parameters: .init(userSession: flowParameters.userSession,
                                                                             mediaUploadingPreprocessor: MediaUploadingPreprocessor(userSettings: userSettings),
                                                                             navigationStackCoordinator: navigationStackCoordinator,
                                                                             appMediator: flowParameters.appMediator,
                                                                             userIndicatorController: flowParameters.userIndicatorController))
        coordinator.actions
            .sink { [weak self] action in
                switch action {
                case .dismiss:
                    self?.navigationStackCoordinator.pop()
                }
            }
            .store(in: &cancellables)
        
        navigationStackCoordinator.push(coordinator)
    }
    
    private func startLinkNewDeviceFlow() {
        let stackCoordinator = NavigationStackCoordinator()
        let flowCoordinator = LinkNewDeviceFlowCoordinator(navigationStackCoordinator: stackCoordinator,
                                                           appLockService: appLockService,
                                                           flowParameters: flowParameters)
        flowCoordinator.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                
                switch action {
                case .dismiss:
                    navigationStackCoordinator.setSheetCoordinator(nil)
                case .requestOAuthAuthorisation(let url, let continuation):
                    presentAccountManagementURL(url, continuation: continuation)
                case .forceLogout:
                    actionsSubject.send(.forceLogout)
                }
            }
            .store(in: &cancellables)
        
        linkNewDeviceFlowCoordinator = flowCoordinator
        flowCoordinator.start()
        
        navigationStackCoordinator.setSheetCoordinator(stackCoordinator) { [weak self] in
            self?.linkNewDeviceFlowCoordinator = nil
        }
    }
    
    private func presentAnalyticsScreen() {
        let coordinator = AnalyticsSettingsScreenCoordinator(parameters: .init(userSettings: userSettings,
                                                                               analytics: flowParameters.analytics))
        navigationStackCoordinator.push(coordinator)
    }
    
    private func presentAppLockSetupFlow() {
        let coordinator = AppLockSetupFlowCoordinator(presentingFlow: .settings,
                                                      appLockService: appLockService,
                                                      navigationStackCoordinator: navigationStackCoordinator)
        coordinator.actions.sink { [weak self] action in
            guard let self else { return }
            switch action {
            case .complete:
                // The flow coordinator tidies up the stack, no need to do anything.
                appLockSetupFlowCoordinator = nil
            case .forceLogout:
                actionsSubject.send(.forceLogout)
            }
        }
        .store(in: &cancellables)
        
        appLockSetupFlowCoordinator = coordinator
        coordinator.start()
    }
    
    private func presentLegalInformationScreen() {
        navigationStackCoordinator.push(LegalInformationScreenCoordinator(userSettings: userSettings))
    }
    
    private func presentBlockedUsersScreen() {
        let coordinator = BlockedUsersScreenCoordinator(parameters: .init(hideProfiles: userSettings.app.hideIgnoredUserProfiles,
                                                                          userSession: flowParameters.userSession,
                                                                          userIndicatorController: flowParameters.userIndicatorController))
        navigationStackCoordinator.push(coordinator)
    }
    
    private func presentNotificationSettings() {
        let notificationParameters = NotificationSettingsScreenCoordinatorParameters(navigationStackCoordinator: navigationStackCoordinator,
                                                                                     userSession: flowParameters.userSession,
                                                                                     userNotificationCenter: UNUserNotificationCenter.current(),
                                                                                     userIndicatorController: flowParameters.userIndicatorController,
                                                                                     isModallyPresented: false)
        let coordinator = NotificationSettingsScreenCoordinator(parameters: notificationParameters)
        navigationStackCoordinator.push(coordinator)
    }
    
    private func presentModerationAndSafetySettings() {
        let parameters = ModerationAndSafetySettingsScreenCoordinatorParameters(userSession: flowParameters.userSession,
                                                                                userIndicatorController: flowParameters.userIndicatorController)
        let coordinator = ModerationAndSafetySettingsScreenCoordinator(parameters: parameters)
        coordinator.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                
                switch action {
                case .blockedUsers:
                    presentBlockedUsersScreen()
                }
            }
            .store(in: &cancellables)
        
        navigationStackCoordinator.push(coordinator)
    }
    
    private func presentMediaUploadQualitySettings() {
        let parameters = MediaUploadQualitySettingsScreenCoordinatorParameters(userSettings: userSettings,
                                                                               analytics: flowParameters.analytics)
        let coordinator = MediaUploadQualitySettingsScreenCoordinator(parameters: parameters)
        navigationStackCoordinator.push(coordinator)
    }
    
    private func presentLocationSharingSettings() {
        let parameters = LocationSharingSettingsScreenCoordinatorParameters(userSettings: userSettings)
        let coordinator = LocationSharingSettingsScreenCoordinator(parameters: parameters)
        navigationStackCoordinator.push(coordinator)
    }
    
    private func presentDeveloperOptions() {
        let coordinator = DeveloperOptionsScreenCoordinator(appSettings: userSettings.app,
                                                            screenHook: flowParameters.userSession.userHooks.developerOptionsScreenHook,
                                                            clientProxy: flowParameters.userSession.clientProxy)
        
        coordinator.actions
            .sink { [weak self] action in
                guard let self else { return }
                
                switch action {
                case .clearCache:
                    actionsSubject.send(.clearCache)
                }
            }
            .store(in: &cancellables)
        
        navigationStackCoordinator.push(coordinator)
    }
    
    private func presentDeactivateAccount() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let url = await flowParameters.userSession.clientProxy.accountURL(action: .accountDeactivate) else {
                MXLog.error("MAS account deactivation URL unavailable.")
                flowParameters.userIndicatorController.submitIndicator(.init(title: L10n.errorUnknown))
                return
            }
            
            presentAccountManagementURL(url)
        }
    }
    
    /// GUA FORK: Find-friends-from-contacts entry-point.
    /// GUA FORK: Two-step verification entry-point.
    private func presentTwoStepVerification(initialSetup: AuthFactor? = nil) {
        guard let identityServiceClient = IdentityServiceClient() else {
            MXLog.warning("Identity service is not configured; cannot show two-step verification screen.")
            return
        }
        let parameters = TwoStepVerificationScreenCoordinatorParameters(clientProxy: flowParameters.userSession.clientProxy,
                                                                        identityServiceClient: identityServiceClient,
                                                                        userIndicatorController: flowParameters.userIndicatorController,
                                                                        windowManager: flowParameters.windowManager,
                                                                        appSettings: userSettings.app,
                                                                        initialSetup: initialSetup)
        let coordinator = TwoStepVerificationScreenCoordinator(parameters: parameters)
        
        coordinator.actionsPublisher
            .sink { _ in }
            .store(in: &cancellables)
        
        navigationStackCoordinator.push(coordinator)
    }
    
    /// GUA FORK: Change-phone-number entry-point.
    private func presentChangePhone() {
        guard let identityServiceClient = IdentityServiceClient() else {
            MXLog.warning("Identity service is not configured; cannot show change phone number screen.")
            return
        }
        let parameters = ChangePhoneScreenCoordinatorParameters(clientProxy: flowParameters.userSession.clientProxy,
                                                                identityServiceClient: identityServiceClient,
                                                                userIndicatorController: flowParameters.userIndicatorController,
                                                                windowManager: flowParameters.windowManager)
        let coordinator = ChangePhoneScreenCoordinator(parameters: parameters)
        
        coordinator.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .close:
                    navigationStackCoordinator.pop()
                case .setUpStepUpFactor(let factor):
                    // The account can produce no step-up factor. Route to the one the user picked,
                    // not to a hardcoded PIN setup: a passkey is the preferred factor, and sending
                    // a passkey user to create a PIN is what the old funnel did. The fresh-2FA hold
                    // runs after either one is created, so there is no auto-return.
                    navigationStackCoordinator.pop()
                    presentTwoStepVerification(initialSetup: factor)
                }
            }
            .store(in: &cancellables)
        
        coordinator.start()
        navigationStackCoordinator.push(coordinator)
    }
    
    private func presentFindFriends() {
        guard let identityServiceClient = IdentityServiceClient() else {
            MXLog.warning("Identity service is not configured; cannot show Find Friends.")
            return
        }
        guard let accessToken = flowParameters.userSession.clientProxy.accessToken else {
            MXLog.warning("No access token available; cannot run contact discovery.")
            return
        }
        let contactDiscoveryService = ContactDiscoveryService(identityServiceClient: identityServiceClient,
                                                              currentUserID: flowParameters.userSession.clientProxy.userID)
        let parameters = FindFriendsScreenCoordinatorParameters(contactDiscoveryService: contactDiscoveryService,
                                                                clientProxy: flowParameters.userSession.clientProxy,
                                                                accessToken: accessToken)
        let coordinator = FindFriendsScreenCoordinator(parameters: parameters)
        
        coordinator.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .startedChat:
                    // The direct room now exists; close Settings so the user lands back on
                    // their chat list where the new conversation appears.
                    actionsSubject.send(.dismiss)
                case .showProfile(let userID):
                    presentFindFriendsUserProfile(userID: userID)
                case .close:
                    break
                }
            }
            .store(in: &cancellables)
        
        navigationStackCoordinator.push(coordinator)
    }
    
    private func presentFindFriendsUserProfile(userID: String) {
        let parameters = UserProfileScreenCoordinatorParameters(userID: userID,
                                                                isPresentedModally: false,
                                                                userSession: flowParameters.userSession,
                                                                analytics: flowParameters.analytics,
                                                                userIndicatorController: flowParameters.userIndicatorController)
        let coordinator = UserProfileScreenCoordinator(parameters: parameters)
        coordinator.actionsPublisher.sink { [weak self] action in
            guard let self else { return }
            switch action {
            case .openDirectChat(let roomID):
                // The direct room now exists; route to it the same way the in-row Find Friends
                // handling does — close Settings so the user lands back on their chat list where
                // the new conversation appears.
                MXLog.info("Find Friends opened direct chat \(roomID); dismissing Settings.")
                actionsSubject.send(.dismiss)
            case .startCall, .dismiss:
                navigationStackCoordinator.pop()
            }
        }
        .store(in: &cancellables)
        
        navigationStackCoordinator.push(coordinator)
    }
    
    // MARK: OAuth Account Management
    
    private var accountSettingsPresenter: OAuthAccountSettingsPresenter?
    private func presentAccountManagementURL(_ url: URL, continuation: OAuthAccountSettingsPresenter.Continuation? = nil) {
        // Note to anyone in the future if you come back here to make this open in Safari instead of a WAS.
        // As of iOS 16, there is an issue on the simulator with accessing the cookie but it works on a device. 🤷‍♂️
        accountSettingsPresenter = OAuthAccountSettingsPresenter(accountURL: url,
                                                                 presentationAnchor: flowParameters.windowManager.mainWindow,
                                                                 appMediator: flowParameters.appMediator,
                                                                 userSession: flowParameters.userSession,
                                                                 continuation: continuation)
        accountSettingsPresenter?.start()
    }
}
