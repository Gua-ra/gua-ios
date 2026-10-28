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
            case .recoverFromOtherDevice:
                presentRecoveryFromOtherDevice()
            case .resetFinished:
                // GUA FORK: stay until key storage is provisioned, which is what clears the setup banner.
                Task { [weak self] in
                    guard let self else { return }

                    // Only a reset that returned normally proves the upload, so the pending marker is
                    // cleared here and nowhere earlier.
                    IdentityResetPendingStore.clear(for: userSession.clientProxy.userID)

                    userIndicatorController.submitIndicator(UserIndicator(id: Self.finishingIndicatorID,
                                                                          type: .modal,
                                                                          title: UntranslatedL10n.guaEncryptionResetFinishing,
                                                                          persistent: true))

                    let outcome = await userSession.clientProxy.secureBackupController.provisionAfterReset()
                    userIndicatorController.retractIndicatorWithId(Self.finishingIndicatorID)

                    switch outcome {
                    case .repaired:
                        MXLog.info("GUA-KEYSTORE: provisioned key storage after the reset.")
                        userIndicatorController.submitIndicator(UserIndicator(title: L10n.commonSuccess))
                    case .notYet, .resetRequired:
                        // The setup banner stays up as the retry.
                        MXLog.error("GUA-KEYSTORE: could not provision key storage after the reset.")
                        userIndicatorController.submitIndicator(UserIndicator(title: L10n.errorUnknown))
                    case .identityIncompleteAfterReset:
                        MXLog.error("GUA-KEYSTORE: the account is incomplete after the reset; leaving it to the banner.")
                        userIndicatorController.submitIndicator(UserIndicator(title: UntranslatedL10n.guaEncryptionResetFailed))
                    }

                    actionsSubject.send(.resetComplete)
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
    
    // MARK: - Recovery from another device

    /// GUA FORK: once the emojis match, the other device sends the keys, so success is the
    /// recovery state turning enabled.
    private func presentRecoveryFromOtherDevice() {
        guard let sessionVerificationController = userSession.clientProxy.sessionVerificationController else {
            MXLog.error("GUA-KEYSTORE: no session verification controller yet, cannot recover from another device.")
            userIndicatorController.submitIndicator(UserIndicator(title: UntranslatedL10n.guaEncryptionRecoverFromOtherDeviceFailed))
            return
        }

        let parameters = SessionVerificationScreenCoordinatorParameters(sessionVerificationControllerProxy: sessionVerificationController,
                                                                        flow: .deviceInitiator,
                                                                        appSettings: appSettings,
                                                                        mediaProvider: userSession.mediaProvider)
        let coordinator = SessionVerificationScreenCoordinator(parameters: parameters)
        coordinator.actions
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .done:
                    navigationStackCoordinator.pop()
                    Task { await self.finishRecoveryFromOtherDevice() }
                case .ignoredOwnDeviceRequest:
                    break
                }
            }
            .store(in: &cancellables)
        navigationStackCoordinator.push(coordinator)
    }

    private func finishRecoveryFromOtherDevice() async {
        userIndicatorController.submitIndicator(UserIndicator(id: Self.finishingIndicatorID,
                                                              type: .modal,
                                                              title: UntranslatedL10n.guaEncryptionResetFinishing,
                                                              persistent: true))
        let recovered = await waitForRecoveryEnabled(timeout: Self.recoveryFromOtherDeviceCeiling)
        userIndicatorController.retractIndicatorWithId(Self.finishingIndicatorID)

        if recovered {
            MXLog.info("GUA-KEYSTORE: keys arrived from the other device.")
            userIndicatorController.submitIndicator(UserIndicator(title: L10n.commonSuccess))
            actionsSubject.send(.resetComplete)
        } else {
            MXLog.warning("GUA-KEYSTORE: keys did not arrive from the other device within the bound.")
            userIndicatorController.submitIndicator(UserIndicator(title: UntranslatedL10n.guaEncryptionRecoverFromOtherDeviceFailed))
        }
    }

    private func waitForRecoveryEnabled(timeout: Duration) async -> Bool {
        let publisher = userSession.clientProxy.secureBackupController.recoveryState
        if publisher.value == .enabled { return true }
        return await withCheckedContinuation { continuation in
            let gate = OnceGate()
            var cancellable: AnyCancellable?
            cancellable = publisher
                .filter { $0 == .enabled }
                .first()
                .sink { _ in
                    gate.resume(continuation, with: true)
                    cancellable?.cancel()
                }
            Task {
                try? await Task.sleep(for: timeout)
                gate.resume(continuation, with: false)
                cancellable?.cancel()
            }
        }
    }

    private final class OnceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false

        func resume(_ continuation: CheckedContinuation<Bool, Never>, with value: Bool) {
            lock.lock()
            defer { lock.unlock() }
            guard !resumed else { return }
            resumed = true
            continuation.resume(returning: value)
        }
    }

    /// Covers one 30 s encryption sync poll with margin; keys that arrive later still clear the banner.
    private static let recoveryFromOtherDeviceCeiling: Duration = .seconds(60)

    private static let finishingIndicatorID = "\(EncryptionResetFlowCoordinator.self)-Finishing"

    private var accountSettingsPresenter: OIDCAccountSettingsPresenter?
    /// GUA FORK: on approval MAS navigates to the scheme passed in `gua_return`, which dismisses the web session.
    /// MAS checks it against an allow-list and builds the URL itself.
    private func approvalURL(_ url: URL) -> URL {
        guard let scheme = appSettings.oidcRedirectURL.scheme,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }

        // GUA FORK: the sheet shares browser cookies, so name this account or MAS may approve the
        // reset for another one.
        let userID = userSession.clientProxy.userID
        let localpart = String(userID.dropFirst().prefix { $0 != ":" })

        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "gua_return", value: scheme))
        items.append(URLQueryItem(name: "gua_user", value: localpart))
        items.append(URLQueryItem(name: "org.matrix.msc4198.login_hint", value: "mxid:\(userID)"))
        components.queryItems = items

        return components.url ?? url
    }

    private func presentOIDCAuthorization(for url: URL, completionPublisher: PassthroughSubject<OIDCAccountSettingsPresenter.Outcome, Never>) {
        // Note to anyone in the future if you come back here to make this open in Safari instead of a WAS.
        // As of iOS 16, there is an issue on the simulator with accessing the cookie but it works on a device. 🤷‍♂️
        let presenter = OIDCAccountSettingsPresenter(accountURL: approvalURL(url),
                                                     presentationAnchor: windowManager.mainWindow,
                                                     appSettings: appSettings)
        accountSettingsPresenter = presenter
        // The reset must only run after the approval sheet closes.
        Task { @MainActor in
            let outcome = await presenter.start()
            completionPublisher.send(outcome)
        }
    }
}
