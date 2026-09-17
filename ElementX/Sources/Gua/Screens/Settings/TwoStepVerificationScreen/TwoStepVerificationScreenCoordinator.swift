//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

struct TwoStepVerificationScreenCoordinatorParameters {
    let clientProxy: ClientProxyProtocol
    let identityServiceClient: IdentityServiceClientProtocol
    let userIndicatorController: UserIndicatorControllerProtocol
    let windowManager: WindowManagerProtocol
    let appSettings: AppSettings
    /// A factor to start setting up on arrival, when the caller already knows which one the user
    /// asked for. `nil` just opens the overview.
    let initialSetup: AuthFactor?
}

enum TwoStepVerificationScreenCoordinatorAction {
    case close
}

final class TwoStepVerificationScreenCoordinator: CoordinatorProtocol {
    private let parameters: TwoStepVerificationScreenCoordinatorParameters
    private let viewModel: TwoStepVerificationScreenViewModelProtocol

    private var cancellables = Set<AnyCancellable>()
    /// Retained for the lifetime of the web flow so the session isn't cancelled early.
    private var enrollmentPresenter: FactorEnrollmentPresenter?

    private let enrollmentIndicatorID = "TwoStepVerificationScreen-Enrollment"

    private let actionsSubject: PassthroughSubject<TwoStepVerificationScreenCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<TwoStepVerificationScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(parameters: TwoStepVerificationScreenCoordinatorParameters) {
        self.parameters = parameters
        viewModel = TwoStepVerificationScreenViewModel(clientProxy: parameters.clientProxy,
                                                       identityServiceClient: parameters.identityServiceClient,
                                                       userIndicatorController: parameters.userIndicatorController,
                                                       passkeyStepUpPresenter: PasskeyStepUpPresenter(presentationAnchor: parameters.windowManager.mainWindow),
                                                       initialSetup: parameters.initialSetup)
    }

    func start() {
        viewModel.actionsPublisher.sink { [weak self] action in
            MXLog.info("Coordinator: received view model action: \(action)")
            guard let self else { return }
            switch action {
            case .close:
                actionsSubject.send(.close)
            case .setUpPasskey:
                Task { await self.startEnrollment(factor: .passkey) }
            case .setUpPin:
                Task { await self.startEnrollment(factor: .pin) }
            }
        }
        .store(in: &cancellables)
    }

    /// The two factors this screen can enroll. Its own small type rather than ``AuthFactor``, which
    /// also names things no enrollment URL exists for: a phone code, and whatever a newer server
    /// calls a factor this build has never heard of.
    private enum EnrollableFactor {
        case passkey
        case pin
    }

    /// Opens the enrollment web session for one factor. Both factors take the same route because
    /// both are durable: the session confirms the account before anything is stored, which a bearer
    /// token on its own does not.
    private func startEnrollment(factor: EnrollableFactor) async {
        guard let accessToken = parameters.clientProxy.accessToken else {
            MXLog.warning("No access token available; cannot start factor enrollment.")
            return
        }

        parameters.userIndicatorController.submitIndicator(UserIndicator(id: enrollmentIndicatorID,
                                                                         type: .modal,
                                                                         title: L10n.commonLoading,
                                                                         persistent: true))
        let enrollURL: URL
        do {
            enrollURL = try await enrollmentURL(for: factor, accessToken: accessToken)
        } catch {
            MXLog.error("Failed to start factor enrollment: \(error)")
            parameters.userIndicatorController.retractIndicatorWithId(enrollmentIndicatorID)
            parameters.userIndicatorController.submitIndicator(UserIndicator(title: (error as? LocalizedError)?.errorDescription ?? L10n.errorUnknown,
                                                                             iconName: "xmark"))
            return
        }
        parameters.userIndicatorController.retractIndicatorWithId(enrollmentIndicatorID)

        let presenter = FactorEnrollmentPresenter(enrollURL: enrollURL,
                                                  presentationAnchor: parameters.windowManager.mainWindow,
                                                  appSettings: parameters.appSettings)
        enrollmentPresenter = presenter
        do {
            try await presenter.start()
        } catch {
            MXLog.error("Factor enrollment failed: \(error)")
            parameters.userIndicatorController.submitIndicator(UserIndicator(title: error.localizedDescription,
                                                                             iconName: "xmark"))
        }
        enrollmentPresenter = nil
        // The session may have added the factor, and the screen has no other way to find out: the
        // report it is rendering was read before the sheet opened.
        viewModel.context.send(viewAction: .retryStatus)
    }

    /// The redirect asked for is this build's own, taken from the same setting the sheet waits on
    /// below (`FactorEnrollmentPresenter` closes when the page redirects to it). The release, QA and
    /// debug builds answer to different schemes, so a deployment that only knows one of them returns
    /// every enrollment to whichever build that is. Asking for it is all the client does: the
    /// server keeps the allowlist, and a value it does not hold costs nothing because the client
    /// asks again without one.
    private func enrollmentURL(for factor: EnrollableFactor, accessToken: String) async throws -> URL {
        let redirectURI = parameters.appSettings.oidcRedirectURL.absoluteString
        switch factor {
        case .passkey:
            return try await parameters.identityServiceClient.startPasskeyEnrollment(accessToken: accessToken,
                                                                                     redirectURI: redirectURI)
        case .pin:
            return try await parameters.identityServiceClient.startPinEnrollment(accessToken: accessToken,
                                                                                 redirectURI: redirectURI)
        }
    }

    func toPresentable() -> AnyView {
        AnyView(TwoStepVerificationScreen(context: viewModel.context))
    }
}
