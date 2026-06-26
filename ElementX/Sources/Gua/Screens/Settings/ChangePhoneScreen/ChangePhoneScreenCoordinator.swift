//
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

struct ChangePhoneScreenCoordinatorParameters {
    let clientProxy: ClientProxyProtocol
    let identityServiceClient: IdentityServiceClientProtocol
    let userIndicatorController: UserIndicatorControllerProtocol
}

enum ChangePhoneScreenCoordinatorAction {
    case close
}

final class ChangePhoneScreenCoordinator: CoordinatorProtocol {
    private let parameters: ChangePhoneScreenCoordinatorParameters
    private let viewModel: ChangePhoneScreenViewModelProtocol

    private var cancellables = Set<AnyCancellable>()

    private let actionsSubject: PassthroughSubject<ChangePhoneScreenCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<ChangePhoneScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(parameters: ChangePhoneScreenCoordinatorParameters) {
        self.parameters = parameters
        viewModel = ChangePhoneScreenViewModel(clientProxy: parameters.clientProxy,
                                               identityServiceClient: parameters.identityServiceClient,
                                               userIndicatorController: parameters.userIndicatorController)
    }

    func start() {
        viewModel.actionsPublisher.sink { [weak self] action in
            MXLog.info("Coordinator: received view model action: \(action)")
            guard let self else { return }
            switch action {
            case .close:
                actionsSubject.send(.close)
            }
        }
        .store(in: &cancellables)
    }

    func toPresentable() -> AnyView {
        AnyView(ChangePhoneScreen(context: viewModel.context))
    }
}
