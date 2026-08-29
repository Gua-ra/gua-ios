//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

// periphery:ignore:all - this is just a phoneEntry remove this comment once generating the final file

import Combine
import SwiftUI

struct PhoneEntryScreenCoordinatorParameters {
    let isLegacyAuthEnabled: Bool
    let initialPhoneNumber: String

    init(isLegacyAuthEnabled: Bool, initialPhoneNumber: String = "") {
        self.isLegacyAuthEnabled = isLegacyAuthEnabled
        self.initialPhoneNumber = initialPhoneNumber
    }
}

enum PhoneEntryScreenCoordinatorAction {
    case `continue`(phoneNumber: String)
    case useLegacyAuth
    /// GUA FORK: sign in by scanning the code shown on a device already signed in.
    case linkWithExistingDevice
}

final class PhoneEntryScreenCoordinator: CoordinatorProtocol {
    private let parameters: PhoneEntryScreenCoordinatorParameters
    private let viewModel: PhoneEntryScreenViewModel

    private var cancellables = Set<AnyCancellable>()

    private let actionsSubject: PassthroughSubject<PhoneEntryScreenCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<PhoneEntryScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(parameters: PhoneEntryScreenCoordinatorParameters) {
        self.parameters = parameters

        viewModel = PhoneEntryScreenViewModel(isLegacyAuthEnabled: parameters.isLegacyAuthEnabled,
                                              initialPhoneNumber: parameters.initialPhoneNumber)
    }

    func start() {
        viewModel.actionsPublisher.sink { [weak self] action in
            guard let self else { return }
            switch action {
            case .continue(let phoneNumber):
                actionsSubject.send(.continue(phoneNumber: phoneNumber))
            case .useLegacyAuth:
                actionsSubject.send(.useLegacyAuth)
            case .linkWithExistingDevice:
                actionsSubject.send(.linkWithExistingDevice)
            }
        }
        .store(in: &cancellables)
    }

    func setSubmitting(_ isSubmitting: Bool) {
        viewModel.setSubmitting(isSubmitting)
    }

    func displayError(_ message: String) {
        viewModel.displayError(message)
    }

    func toPresentable() -> AnyView {
        AnyView(PhoneEntryScreen(context: viewModel.context))
    }
}
