//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

typealias SettingsScreenViewModelType = StateStoreViewModelV2<SettingsScreenViewState, SettingsScreenViewAction>

class SettingsScreenViewModel: SettingsScreenViewModelType, SettingsScreenViewModelProtocol {
    private let appSettings: AppSettings
    private let spacesSetting: SpacesSetting
    private let userIndicatorController: UserIndicatorControllerProtocol
    
    private var actionsSubject: PassthroughSubject<SettingsScreenViewModelAction, Never> = .init()
    
    var actions: AnyPublisher<SettingsScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(userSession: UserSessionProtocol,
         appSettings: AppSettings,
         spacesSetting: SpacesSetting,
         userIndicatorController: UserIndicatorControllerProtocol,
         isBugReportServiceEnabled: Bool) {
        self.appSettings = appSettings
        self.spacesSetting = spacesSetting
        self.userIndicatorController = userIndicatorController
        
        super.init(initialViewState: .init(deviceID: userSession.clientProxy.deviceID,
                                           userID: userSession.clientProxy.userID,
                                           showAccountDeactivation: userSession.clientProxy.canDeactivateAccount,
                                           showDeveloperOptions: appSettings.developerOptionsEnabled,
                                           showAnalyticsSettings: appSettings.canPromptForAnalytics,
                                           isBugReportServiceEnabled: isBugReportServiceEnabled,
                                           bindings: .init(appSettings: appSettings)),
                   mediaProvider: userSession.mediaProvider)
        
        appSettings.$developerOptionsEnabled
            .weakAssign(to: \.state.showDeveloperOptions, on: self)
            .store(in: &cancellables)
        
        appSettings.$spacesEnabled
            .weakAssign(to: \.state.bindings.isSpacesEnabled, on: self)
            .store(in: &cancellables)
        
        Task { await spacesSetting.refresh() }

        userSession.clientProxy.userAvatarURLPublisher
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.state.userAvatarURL, on: self)
            .store(in: &cancellables)
        
        userSession.clientProxy.userDisplayNamePublisher
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.state.userDisplayName, on: self)
            .store(in: &cancellables)
        
        Task {
            await userSession.clientProxy.loadUserAvatarURL()
            await userSession.clientProxy.loadUserDisplayName()
            await state.accountProfileURL = userSession.clientProxy.accountURL(action: .profile)
        }
    }
    
    override func process(viewAction: SettingsScreenViewAction) {
        switch viewAction {
        case .close:
            actionsSubject.send(.close)
            
        case .userDetails:
            actionsSubject.send(.userDetails)
            
        case .findFriends:
            actionsSubject.send(.findFriends)
            
        case let .manageAccount(url):
            actionsSubject.send(.manageAccount(url: url))
        case .twoStepVerification:
            actionsSubject.send(.twoStepVerification)
        case .changePhoneNumber:
            actionsSubject.send(.changePhoneNumber)
        case .notifications:
            actionsSubject.send(.notifications)
        case .moderationAndSafety:
            actionsSubject.send(.moderationAndSafety)
        case .reportBug:
            actionsSubject.send(.reportBug)
            
        case .logout:
            actionsSubject.send(.logout)
        case .deactivateAccount:
            actionsSubject.send(.deactivateAccount)
            
        case .toggleSpaces:
            let isEnabled = state.bindings.isSpacesEnabled
            guard isEnabled != appSettings.spacesEnabled else { return }
            Task {
                if case .failure(let error) = await spacesSetting.setEnabled(isEnabled) {
                    MXLog.error("Failed changing the Spaces switch: \(error)")
                    userIndicatorController.submitIndicator(.init(title: L10n.errorUnknown))
                }
            }
        case .mediaUploadQuality:
            actionsSubject.send(.mediaUploadQuality)
        case .appLock:
            actionsSubject.send(.appLock)
        case .analytics:
            actionsSubject.send(.analytics)
        case .about:
            actionsSubject.send(.about)
            
        case .enableDeveloperOptions:
            appSettings.developerOptionsEnabled.toggle()
        case .developerOptions:
            actionsSubject.send(.developerOptions)
        }
    }
}
