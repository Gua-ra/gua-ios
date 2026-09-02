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
                // GUA FORK: hold the user here, visibly, until the account is actually finished.
                //
                // The reset has landed but recovery is still disabled, and provisioning it is what
                // clears the setup banner. Dismissing before that put people back on the chat list
                // with the banner still up -- a phantom, since nothing was wrong any more except
                // that the work had not finished -- so they pressed it, and the press looked like
                // what fixed the account.
                //
                // So: one blocking wait that says wait, then a confirmation that says it worked,
                // and only then back to the chat list, by which point the banner is genuinely gone.
                // It takes about a second, and there is nothing here for the user to get wrong.
                Task { [weak self] in
                    guard let self else { return }

                    // The reset has landed on the server: the SDK call returned normally and was
                    // never cancelled, which is the only signal that proves the upload. Only now
                    // may the pending marker go and key storage be provisioned.
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
                        // The banner is still up and is now the retry, so this is not a dead end.
                        MXLog.error("GUA-KEYSTORE: could not provision key storage after the reset.")
                        userIndicatorController.submitIndicator(UserIndicator(title: L10n.errorUnknown))
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

    /// GUA FORK: verifies this device with another device of the account. Once the two agree on
    /// the emojis, the SDK asks that device for the keys and it hands them over; nothing is reset
    /// and no recovery key is involved. The verdict is the recovery state: enabled means the keys
    /// (and the backup key with them) arrived; anything else within the bound is an honest "not
    /// yet", and the reset screen stays with both options.
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

    /// The other device answers within a second or two once the emojis match, but the keys ride
    /// on the encryption sync, which polls every 30 s at rest. The bound covers one poll with
    /// margin; it only exists so that a device that never answers cannot hold the user on a
    /// spinner. If the keys arrive after it, the banner still clears by itself.
    private static let recoveryFromOtherDeviceCeiling: Duration = .seconds(60)

    private static let finishingIndicatorID = "\(EncryptionResetFlowCoordinator.self)-Finishing"

    private var accountSettingsPresenter: OIDCAccountSettingsPresenter?
    /// GUA FORK: tells MAS which app scheme to hand control back to when the reset is approved.
    ///
    /// MAS's success page used to be a dead end -- it said "go back to the app" and the user had to
    /// close the sheet by hand. Given this, it navigates to the scheme instead, which is what makes
    /// ASWebAuthenticationSession dismiss itself. MAS compares the value against a fixed allow-list
    /// and builds the URL itself, so this names an app rather than supplying a destination.
    private func approvalURL(_ url: URL) -> URL {
        guard let scheme = appSettings.oidcRedirectURL.scheme,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }

        // GUA FORK: name the account this app is signed in as. The sheet shares cookies with the
        // system browser, so the page can otherwise open under some other account's session and
        // approve the reset for that account while ours keeps being refused. The server compares
        // and, on a mismatch, signs that session out and asks for a login as this account first.
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
        // Wait for the approval sheet to be dismissed before signalling the view model,
        // so the reset runs only once the user has approved it in MAS.
        Task { @MainActor in
            let outcome = await presenter.start()
            completionPublisher.send(outcome)
        }
    }
}
