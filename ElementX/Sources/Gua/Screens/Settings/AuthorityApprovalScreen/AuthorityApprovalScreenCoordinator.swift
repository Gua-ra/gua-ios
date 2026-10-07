//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Combine
import SwiftUI

struct AuthorityApprovalScreenCoordinatorParameters {
    let authorityService: AccountAuthorityServiceProtocol
    let clientProxy: ClientProxyProtocol
    let userIndicatorController: UserIndicatorControllerProtocol
}

enum AuthorityApprovalScreenCoordinatorAction {
    case close
}

final class AuthorityApprovalScreenCoordinator: CoordinatorProtocol {
    private let viewModel: AuthorityApprovalScreenViewModelProtocol

    private var cancellables = Set<AnyCancellable>()

    private let actionsSubject: PassthroughSubject<AuthorityApprovalScreenCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<AuthorityApprovalScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(parameters: AuthorityApprovalScreenCoordinatorParameters) {
        viewModel = AuthorityApprovalScreenViewModel(authorityService: parameters.authorityService,
                                                     clientProxy: parameters.clientProxy,
                                                     userIndicatorController: parameters.userIndicatorController)
    }

    func start() {
        viewModel.actionsPublisher.sink { [weak self] action in
            switch action {
            case .close:
                self?.actionsSubject.send(.close)
            }
        }
        .store(in: &cancellables)
    }

    func toPresentable() -> AnyView {
        AnyView(AuthorityApprovalScreen(context: viewModel.context))
    }
}
