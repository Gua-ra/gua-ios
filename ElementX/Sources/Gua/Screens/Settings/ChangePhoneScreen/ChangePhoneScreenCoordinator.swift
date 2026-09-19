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
    let windowManager: WindowManagerProtocol
}

enum ChangePhoneScreenCoordinatorAction {
    case close
    /// The account can produce no step-up factor and the user picked one to set up. The Settings
    /// flow opens that one, rather than assuming the PIN.
    case setUpStepUpFactor(AuthFactor)
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
        // The assertion is run natively here rather than in a web view: the step-up ceremony hands
        // back WebAuthn options, not a page, and the assertion has to come back as JSON.
        viewModel = ChangePhoneScreenViewModel(clientProxy: parameters.clientProxy,
                                               identityServiceClient: parameters.identityServiceClient,
                                               userIndicatorController: parameters.userIndicatorController,
                                               passkeyStepUpPresenter: PasskeyStepUpPresenter(presentationAnchor: parameters.windowManager.mainWindow))
    }

    func start() {
        viewModel.actionsPublisher.sink { [weak self] action in
            MXLog.info("Coordinator: received view model action: \(action)")
            guard let self else { return }
            switch action {
            case .close:
                actionsSubject.send(.close)
            case .setUpStepUpFactor(let factor):
                actionsSubject.send(.setUpStepUpFactor(factor))
            }
        }
        .store(in: &cancellables)
    }

    func toPresentable() -> AnyView {
        AnyView(ChangePhoneScreen(context: viewModel.context))
    }
}
