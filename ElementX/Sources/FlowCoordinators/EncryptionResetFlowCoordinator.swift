//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import SwiftState

enum EncryptionResetFlowCoordinatorAction: Equatable {
    /// The flow is complete.
    case resetComplete
    /// The flow was cancelled.
    case cancel
}

struct EncryptionResetFlowCoordinatorParameters {
    let userSession: UserSessionProtocol
    let appSettings: AppSettings
    let userIndicatorController: UserIndicatorControllerProtocol
    let navigationStackCoordinator: NavigationStackCoordinator
    let windowManger: WindowManagerProtocol
}

class EncryptionResetFlowCoordinator: FlowCoordinatorProtocol {
    private let userSession: UserSessionProtocol
    private let appSettings: AppSettings
    private let userIndicatorController: UserIndicatorControllerProtocol
    
    private let navigationStackCoordinator: NavigationStackCoordinator
    private let windowManager: WindowManagerProtocol
    
    enum State: StateType {
        /// The state machine hasn't started.
        case initial
        /// The root screen for this flow.
        case encryptionResetScreen
        /// Confirming the user's password to continue.
        case confirmingPassword
    }
    
    enum Event: EventType {
        /// The flow is being started.
        case start
        
        /// The user needs to confirm their password to reset.
        case confirmPassword
        /// The user confirmed their password.
        case finishedConfirmingPassword
    }
    
    private let stateMachine: StateMachine<State, Event>
    private var cancellables: Set<AnyCancellable> = []
    
    private let actionsSubject: PassthroughSubject<EncryptionResetFlowCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<EncryptionResetFlowCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(parameters: EncryptionResetFlowCoordinatorParameters) {
        userSession = parameters.userSession
        appSettings = parameters.appSettings
        userIndicatorController = parameters.userIndicatorController
        navigationStackCoordinator = parameters.navigationStackCoordinator
        windowManager = parameters.windowManger
        
        stateMachine = .init(state: .initial)
        configureStateMachine()
    }
    
    func start() {
        stateMachine.tryEvent(.start)
    }
    
    func handleAppRoute(_ appRoute: AppRoute, animated: Bool) {
        // There aren't any routes to this screen, so always clear the stack.
        clearRoute(animated: animated)
    }
    
    func clearRoute(animated: Bool) {
        // As we push screens on top of an existing stack, popping to root wouldn't be safe.
        switch stateMachine.state {
        case .initial:
            break
        case .encryptionResetScreen:
            navigationStackCoordinator.pop(animated: animated)
        case .confirmingPassword:
            navigationStackCoordinator.pop(animated: animated) // Password screen.
            navigationStackCoordinator.pop(animated: animated) // EncryptionReset screen.
        }
    }
    
    // MARK: - Private
    
    private func configureStateMachine() {
        stateMachine.addRoutes(event: .start, transitions: [.initial => .encryptionResetScreen]) { [weak self] _ in
            self?.presentEncryptionResetScreen()
        }
        
        stateMachine.addRoutes(event: .confirmPassword, transitions: [.encryptionResetScreen => .confirmingPassword]) { [weak self] context in
            guard let passwordPublisher = context.userInfo as? PassthroughSubject<String, Never> else { fatalError("Expected a publisher in the userInfo.") }
            self?.presentPasswordScreen(passwordPublisher: passwordPublisher)
        }
        stateMachine.addRoutes(event: .finishedConfirmingPassword, transitions: [.confirmingPassword => .encryptionResetScreen])
        
        stateMachine.addErrorHandler { context in
            fatalError("Unexpected transition: \(context)")
        }
    }
    
    private func presentEncryptionResetScreen() {
        let coordinator = EncryptionResetScreenCoordinator(parameters: .init(clientProxy: userSession.clientProxy,
                                                                             userIndicatorController: userIndicatorController))
        
        coordinator.actionsPublisher.sink { [weak self] action in
            guard let self else { return }
            
            switch action {
            case .requestOIDCAuthorisation(let url, let completionPublisher):
                presentOIDCAuthorization(for: url, completionPublisher: completionPublisher)
            case .dismissOIDCPresentation:
                accountSettingsPresenter?.dismiss()
                accountSettingsPresenter = nil
            case .requestPassword(let passwordPublisher):
                stateMachine.tryEvent(.confirmPassword, userInfo: passwordPublisher)
            case .cancel:
                actionsSubject.send(.cancel)
            case .resetFinished:
                // GUA FORK: leave FIRST, provision after.
                //
                // A reset destroys the key backup and leaves recovery disabled. Upstream expects
                // the user to walk the "set up recovery" flow from there and write down a recovery
                // key; Gua shows nobody a recovery key, so we provision it ourselves. That used to
                // happen here, awaited, before `.resetComplete` was sent -- and `.resetComplete` is
                // the only thing that dismisses this flow. So the user sat on the destructive
                // confirmation screen for the length of the provisioning, with the one spinner in
                // the flow already retracted, looking at a live "Reset and finish setup" button
                // with nothing to tell them what was happening. The obvious move from there is to
                // press it again, which is the loop back into MAS.
                //
                // The reset itself has landed by this point, so there is nothing left to keep them
                // for. Dismiss, then provision behind the chat list: it needs no input, its
                // outcome is visible in the banner, and SecureBackupController serialises it
                // against a tap on that banner.
                actionsSubject.send(.resetComplete)

                Task { [userSession] in
                    switch await userSession.clientProxy.secureBackupController.provisionAfterReset() {
                    case .repaired:
                        MXLog.info("GUA-KEYSTORE: provisioned key storage after the reset.")
                    case .notYet, .resetRequired:
                        // The banner is still up and is now the retry: this is not a dead end.
                        MXLog.error("GUA-KEYSTORE: could not provision key storage after the reset.")
                    }
                }
            }
        }
        .store(in: &cancellables)
        
        navigationStackCoordinator.setRootCoordinator(coordinator)
    }
    
    private func presentPasswordScreen(passwordPublisher: PassthroughSubject<String, Never>) {
        let coordinator = EncryptionResetPasswordScreenCoordinator(parameters: .init(passwordPublisher: passwordPublisher,
                                                                                     clientProxy: userSession.clientProxy,
                                                                                     identityServiceClient: IdentityServiceClient()))
        
        coordinator.actionsPublisher.sink { [weak self] action in
            guard let self else { return }
            
            switch action {
            case .passwordEntered:
                navigationStackCoordinator.pop()
            }
        }
        .store(in: &cancellables)
        
        navigationStackCoordinator.push(coordinator) { [stateMachine] in
            stateMachine.tryEvent(.finishedConfirmingPassword)
        }
    }
    
    private var accountSettingsPresenter: OIDCAccountSettingsPresenter?
    private func presentOIDCAuthorization(for url: URL, completionPublisher: PassthroughSubject<Void, Never>) {
        // Note to anyone in the future if you come back here to make this open in Safari instead of a WAS.
        // As of iOS 16, there is an issue on the simulator with accessing the cookie but it works on a device. 🤷‍♂️
        let presenter = OIDCAccountSettingsPresenter(accountURL: url,
                                                     presentationAnchor: windowManager.mainWindow,
                                                     appSettings: appSettings)
        accountSettingsPresenter = presenter
        // Wait for the approval sheet to be dismissed before signalling the view model,
        // so the reset runs only once the user has approved it in MAS.
        Task { @MainActor in
            await presenter.start()
            completionPublisher.send(())
        }
    }
}
