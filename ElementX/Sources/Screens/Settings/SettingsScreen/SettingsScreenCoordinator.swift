//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

struct SettingsScreenCoordinatorParameters {
    let userSession: UserSessionProtocol
    let appSettings: AppSettings
    let spacesSetting: SpacesSetting
    let userIndicatorController: UserIndicatorControllerProtocol
    let isBugReportServiceEnabled: Bool
}

enum SettingsScreenCoordinatorAction {
    case dismiss
    
    case userDetails
    
    case findFriends
    
    case manageAccount(url: URL)
    case twoStepVerification
    case changePhoneNumber
    case notifications
    case moderationAndSafety
    case bugReport
    
    case logout
    case deactivateAccount
    
    case chatTheme
    case mediaUploadQuality
    case appLock
    case analytics
    case about
    
    case developerOptions
}

final class SettingsScreenCoordinator: CoordinatorProtocol {
    private var viewModel: SettingsScreenViewModelProtocol
    
    private let actionsSubject: PassthroughSubject<SettingsScreenCoordinatorAction, Never> = .init()
    var actions: AnyPublisher<SettingsScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Setup
    
    init(parameters: SettingsScreenCoordinatorParameters) {
        viewModel = SettingsScreenViewModel(userSession: parameters.userSession,
                                            appSettings: parameters.appSettings,
                                            spacesSetting: parameters.spacesSetting,
                                            userIndicatorController: parameters.userIndicatorController,
                                            isBugReportServiceEnabled: parameters.isBugReportServiceEnabled)
        
        viewModel.actions
            .sink { [weak self] action in
                guard let self else { return }
                
                switch action {
                case .close:
                    actionsSubject.send(.dismiss)
                    
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
                    actionsSubject.send(.bugReport)
                    
                case .logout:
                    actionsSubject.send(.logout)
                case .deactivateAccount:
                    actionsSubject.send(.deactivateAccount)
                    
                case .chatTheme:
                    actionsSubject.send(.chatTheme)
                case .mediaUploadQuality:
                    actionsSubject.send(.mediaUploadQuality)
                case .appLock:
                    actionsSubject.send(.appLock)
                case .analytics:
                    actionsSubject.send(.analytics)
                case .about:
                    actionsSubject.send(.about)
                    
                case .developerOptions:
                    actionsSubject.send(.developerOptions)
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Public
    
    func toPresentable() -> AnyView {
        AnyView(SettingsScreen(context: viewModel.context))
    }
}
