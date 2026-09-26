//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Combine
import SwiftUI

struct AccountAuthorityScreenCoordinatorParameters {
    let authorityService: AccountAuthorityServiceProtocol
    let identityServiceClient: IdentityServiceClientProtocol
    let clientProxy: ClientProxyProtocol
    let userIndicatorController: UserIndicatorControllerProtocol
    let windowManager: WindowManagerProtocol
    /// Read for this build's own OIDC redirect, which is what the web step-up sheet closes back into.
    let appSettings: AppSettings
}

enum AccountAuthorityScreenCoordinatorAction {
    case close
    case showApprovals
}

final class AccountAuthorityScreenCoordinator: CoordinatorProtocol {
    private let viewModel: AccountAuthorityScreenViewModelProtocol

    private var cancellables = Set<AnyCancellable>()

    private let actionsSubject: PassthroughSubject<AccountAuthorityScreenCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<AccountAuthorityScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(parameters: AccountAuthorityScreenCoordinatorParameters) {
        viewModel = AccountAuthorityScreenViewModel(authorityService: parameters.authorityService,
                                                    identityServiceClient: parameters.identityServiceClient,
                                                    clientProxy: parameters.clientProxy,
                                                    userIndicatorController: parameters.userIndicatorController,
                                                    passkeyStepUpPresenter: PasskeyStepUpPresenter(presentationAnchor: parameters.windowManager.mainWindow),
                                                    webStepUpPresenter: AuthorityWebStepUpPresenter(presentationAnchor: parameters.windowManager.mainWindow,
                                                                                                    appSettings: parameters.appSettings))
    }

    func start() {
        viewModel.actionsPublisher.sink { [weak self] action in
            guard let self else { return }
            switch action {
            case .close:
                actionsSubject.send(.close)
            case .showApprovals:
                actionsSubject.send(.showApprovals)
            }
        }
        .store(in: &cancellables)
    }

    func toPresentable() -> AnyView {
        AnyView(AccountAuthorityScreen(context: viewModel.context))
    }
}
