//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftState
import SwiftUI

@MainActor
protocol AuthenticationFlowCoordinatorDelegate: AnyObject {
    func authenticationFlowCoordinator(didLoginWithSession userSession: UserSessionProtocol)
}

class AuthenticationFlowCoordinator: FlowCoordinatorProtocol {
    private let authenticationService: AuthenticationServiceProtocol
    private let bugReportService: BugReportServiceProtocol
    private let navigationRootCoordinator: NavigationRootCoordinator
    private let navigationStackCoordinator: NavigationStackCoordinator
    private let appMediator: AppMediatorProtocol
    private let appSettings: AppSettings
    private let analytics: AnalyticsService
    private let userIndicatorController: UserIndicatorControllerProtocol
    private let resolverClient: ResolverClientProtocol? // GUA FORK: phone -> homeserver routing
    private let accountGenesisService: AccountGenesisServiceProtocol? // GUA FORK: ADM-008 account genesis
    private let resolverVerifier: ResolverVerifying? // GUA FORK: report-only resolver verification
    private let usesPhoneLoginHint: Bool // GUA FORK
    private let oidcPresenterFactory: ((UIWindow) -> OIDCAuthenticationPresenterProtocol)? // GUA FORK
    
    enum State: StateType {
        /// The state machine hasn't started.
        case initial
        
        /// GUA FORK: the default entry point.
        case phoneEntryScreen
        
        /// The initial screen shown when you first launch the app.
        case startScreen
        
        /// The screen used for the whole QR Code flow.
        case qrCodeLoginScreen
        
        /// The screen to continue authentication with the current server.
        case serverConfirmationScreen
        /// The screen to choose a different server.
        case serverSelectionScreen
        /// The web authentication session is being presented.
        case oidcAuthentication
        /// The screen to login with a password.
        case loginScreen
        
        /// The screen to report an error.
        case bugReportFlow
        
        /// The flow is complete.
        case complete
    }
    
    enum Event: EventType {
        /// The legacy flow is being started.
        case start
        /// Modify the flow using the provisioning parameters in the `userInfo`.
        case applyProvisioningParameters
        /// GUA FORK BEGIN: Gua phone-OIDC events
        case startPhoneAuth
        /// The user dropped into the legacy auth flow from the phone screen.
        case useLegacyAuth
        // GUA FORK END
        
        /// The user would like to login with a QR code.
        case loginWithQR
        /// Show the server confirmation screen.
        case confirmServer(AuthenticationFlow)
        /// The user encountered a problem.
        case reportProblem
        
        /// The QR login flow was aborted.
        case cancelledLoginWithQR
        /// The user aborted manual login.
        case cancelledServerConfirmation
        
        /// The user would like to enter a different server.
        case changeServer(AuthenticationFlow)
        /// The user is no longer selecting a server.
        case dismissedServerSelection
        
        /// Show the web authentication session for OIDC (using the parameters in the `userInfo`).
        case continueWithOIDC
        /// The web authentication session was aborted.
        case cancelledOIDCAuthentication(previousState: State)
        /// Show the screen to login with password (with the optional login hint in the `userInfo`).
        case continueWithPassword
        /// The password login was aborted.
        case cancelledPasswordLogin(previousState: State)
        
        /// The user has finished reporting a problem (or viewing the logs).
        case bugReportFlowComplete
        
        /// The user has successfully signed in. The new session can be found in the `userInfo`.
        case signedIn
    }
    
    private let stateMachine: StateMachine<State, Event>
    private var cancellables = Set<AnyCancellable>()
    
    private var oidcPresenter: OIDCAuthenticationPresenterProtocol?
    
    // periphery:ignore - retaining purpose
    private var bugReportFlowCoordinator: BugReportFlowCoordinator?
    // periphery:ignore - retaining purpose
    private var phoneEntryScreenCoordinator: PhoneEntryScreenCoordinator?
    private var isHandlingPhoneSubmission = false
    /// GUA FORK: held only for the signup that registered it; the attach proof is signed against it.
    private var pendingAccountGenesis: PendingAccountGenesis?
    
    weak var delegate: AuthenticationFlowCoordinatorDelegate?
    
    init(authenticationService: AuthenticationServiceProtocol,
         bugReportService: BugReportServiceProtocol,
         navigationRootCoordinator: NavigationRootCoordinator,
         appMediator: AppMediatorProtocol,
         appSettings: AppSettings,
         analytics: AnalyticsService,
         userIndicatorController: UserIndicatorControllerProtocol,
         resolverClient: ResolverClientProtocol? = nil,
         accountGenesisService: AccountGenesisServiceProtocol? = nil,
         resolverVerifier: ResolverVerifying? = nil,
         usesPhoneLoginHint: Bool = false,
         oidcPresenterFactory: ((UIWindow) -> OIDCAuthenticationPresenterProtocol)? = nil) {
        self.authenticationService = authenticationService
        self.bugReportService = bugReportService
        self.navigationRootCoordinator = navigationRootCoordinator
        self.appMediator = appMediator
        self.appSettings = appSettings
        self.analytics = analytics
        self.userIndicatorController = userIndicatorController
        self.resolverClient = resolverClient
        self.accountGenesisService = accountGenesisService
        self.resolverVerifier = resolverVerifier
        self.usesPhoneLoginHint = usesPhoneLoginHint
        self.oidcPresenterFactory = oidcPresenterFactory
        
        navigationStackCoordinator = NavigationStackCoordinator()
        
        stateMachine = .init(state: .initial)
        configureStateMachine()
    }
    
    /// GUA FORK: starts on the phone-entry screen instead of the start screen.
    private var usesPhoneFlow: Bool {
        usesPhoneLoginHint && !appSettings.legacyAuthEnabled
    }
    
    func start() {
        if usesPhoneFlow {
            stateMachine.tryEvent(.startPhoneAuth)
        } else {
            stateMachine.tryEvent(.start)
        }
    }
    
    func handleAppRoute(_ appRoute: AppRoute, animated: Bool) {
        switch appRoute {
        case .accountProvisioningLink(let provisioningParameters):
            guard appSettings.allowOtherAccountProviders else {
                MXLog.error("Provisioning links not allowed, ignoring.")
                return
            }
            
            // GUA FORK: the phone flow takes its account provider from the resolver, so a provisioning
            // link must not cancel a sign-in or leave the phone-entry screen.
            guard !usesPhoneFlow else {
                MXLog.warning("Ignoring a provisioning link in the phone flow.")
                return
            }
            
            if stateMachine.state != .startScreen {
                clearRoute(animated: animated)
            }
            
            // GUA FORK: a cancelled web authentication session leaves `.oidcAuthentication` asynchronously.
            guard stateMachine.state == .initial || stateMachine.state == .startScreen else {
                MXLog.warning("Ignoring a provisioning link in state `\(stateMachine.state)`.")
                return
            }
            
            stateMachine.tryEvent(.applyProvisioningParameters, userInfo: provisioningParameters)
        default:
            fatalError()
        }
    }
    
    func clearRoute(animated: Bool) {
        switch stateMachine.state {
        case .initial, .startScreen, .phoneEntryScreen:
            break
        case .qrCodeLoginScreen:
            navigationStackCoordinator.setSheetCoordinator(nil)
            stateMachine.tryEvent(.cancelledLoginWithQR) // Needs to be handled manually.
        case .serverConfirmationScreen:
            navigationStackCoordinator.popToRoot(animated: animated)
        case .serverSelectionScreen:
            navigationStackCoordinator.setSheetCoordinator(nil)
            navigationStackCoordinator.popToRoot(animated: animated)
        case .oidcAuthentication:
            oidcPresenter?.cancel()
            navigationStackCoordinator.popToRoot(animated: animated)
        case .loginScreen:
            navigationStackCoordinator.popToRoot(animated: animated)
        case .bugReportFlow:
            navigationStackCoordinator.setSheetCoordinator(nil)
        case .complete:
            fatalError()
        }
    }
    
    // MARK: - Setup
    
    private func configureStateMachine() {
        stateMachine.addRoutes(event: .start, transitions: [.initial => .startScreen]) { [weak self] _ in
            self?.showStartScreen(fromState: .initial)
        }
        
        // Gua phone-OIDC flow

        stateMachine.addRoutes(event: .startPhoneAuth, transitions: [.initial => .phoneEntryScreen]) { [weak self] _ in
            self?.showPhoneEntryScreen(fromState: .initial)
        }
        stateMachine.addRoutes(event: .useLegacyAuth, transitions: [.phoneEntryScreen => .startScreen]) { [weak self] _ in
            self?.showStartScreen(fromState: .phoneEntryScreen)
        }
        
        stateMachine.addRoutes(event: .applyProvisioningParameters, transitions: [.initial => .startScreen,
                                                                                  .startScreen => .startScreen]) { [weak self] context in
            guard let provisioningParameters = context.userInfo as? AccountProvisioningParameters else { fatalError("The authentication configuration is missing.") }
            self?.showStartScreen(fromState: context.fromState, applying: provisioningParameters)
        }
        
        // QR Code
        
        stateMachine.addRoutes(event: .loginWithQR, transitions: [.startScreen => .qrCodeLoginScreen]) { [weak self] _ in
            self?.showQRCodeLoginScreen()
        }
        stateMachine.addRoutes(event: .cancelledLoginWithQR, transitions: [.qrCodeLoginScreen => .startScreen])
        
        // Manual Authentication
        
        stateMachine.addRoutes(event: .confirmServer(.login), transitions: [.startScreen => .serverConfirmationScreen]) { [weak self] _ in
            self?.showServerConfirmationScreen(authenticationFlow: .login)
        }
        stateMachine.addRoutes(event: .confirmServer(.register), transitions: [.startScreen => .serverConfirmationScreen]) { [weak self] _ in
            self?.showServerConfirmationScreen(authenticationFlow: .register)
        }
        stateMachine.addRoutes(event: .cancelledServerConfirmation, transitions: [.serverConfirmationScreen => .startScreen])
        
        stateMachine.addRoutes(event: .changeServer(.login), transitions: [.serverConfirmationScreen => .serverSelectionScreen]) { [weak self] _ in
            self?.showServerSelectionScreen(authenticationFlow: .login)
        }
        stateMachine.addRoutes(event: .changeServer(.register), transitions: [.serverConfirmationScreen => .serverSelectionScreen]) { [weak self] _ in
            self?.showServerSelectionScreen(authenticationFlow: .register)
        }
        stateMachine.addRoutes(event: .dismissedServerSelection, transitions: [.serverSelectionScreen => .serverConfirmationScreen])
        
        stateMachine.addRoutes(event: .continueWithOIDC, transitions: [.phoneEntryScreen => .oidcAuthentication,
                                                                       .serverConfirmationScreen => .oidcAuthentication,
                                                                       .startScreen => .oidcAuthentication]) { [weak self] context in
            guard let (oidcData, window) = context.userInfo as? (OIDCAuthorizationDataProxy, UIWindow) else {
                fatalError("Missing the OIDC data and presentation anchor.")
            }
            self?.showOIDCAuthentication(oidcData: oidcData, presentationAnchor: window, fromState: context.fromState)
        }
        stateMachine.addRoutes(event: .cancelledOIDCAuthentication(previousState: .phoneEntryScreen), transitions: [.oidcAuthentication => .phoneEntryScreen]) { [weak self] _ in
            self?.phoneEntryScreenCoordinator?.setSubmitting(false)
        }
        stateMachine.addRoutes(event: .cancelledOIDCAuthentication(previousState: .serverConfirmationScreen), transitions: [.oidcAuthentication => .serverConfirmationScreen])
        stateMachine.addRoutes(event: .cancelledOIDCAuthentication(previousState: .startScreen), transitions: [.oidcAuthentication => .startScreen])
        
        stateMachine.addRoutes(event: .continueWithPassword, transitions: [.serverConfirmationScreen => .loginScreen,
                                                                           .startScreen => .loginScreen]) { [weak self] context in
            let loginHint = context.userInfo as? String
            self?.showLoginScreen(loginHint: loginHint, fromState: context.fromState)
        }
        stateMachine.addRoutes(event: .cancelledPasswordLogin(previousState: .serverConfirmationScreen), transitions: [.loginScreen => .serverConfirmationScreen])
        stateMachine.addRoutes(event: .cancelledPasswordLogin(previousState: .startScreen), transitions: [.loginScreen => .startScreen])
        
        // Bug Report
        
        stateMachine.addRoutes(event: .reportProblem, transitions: [.startScreen => .bugReportFlow]) { [weak self] _ in
            self?.startBugReportFlow()
        }
        stateMachine.addRoutes(event: .bugReportFlowComplete, transitions: [.bugReportFlow => .startScreen])
        
        // Completion
        
        stateMachine.addRoutes(event: .signedIn, transitions: [.qrCodeLoginScreen => .complete,
                                                               .oidcAuthentication => .complete,
                                                               .loginScreen => .complete]) { [weak self] context in
            guard let userSession = context.userInfo as? UserSessionProtocol else { fatalError("The user session wasn't included in the context") }
            self?.userHasSignedIn(userSession: userSession)
        }
        
        // Logging
        
        stateMachine.addAnyHandler(.any => .any) { context in
            MXLog.info("Transitioning from `\(context.fromState)` to `\(context.toState)` with event `\(String(describing: context.event))`.")
        }
        
        // Unhandled
        
        stateMachine.addErrorHandler { context in
            guard Self.ignoresUnroutedEvent(context.event, from: context.fromState) else {
                fatalError("Unexpected transition: \(context)")
            }
            MXLog.info("Ignoring event `\(String(describing: context.event))` in state `\(context.fromState)`.")
        }
    }
    
    /// Whether an event with no route from `state` is dropped instead of trapping. A repeated
    /// `continueWithOIDC` can arrive before the web authentication session covers the screen.
    static func ignoresUnroutedEvent(_ event: Event?, from state: State) -> Bool {
        switch (state, event) {
        case (.complete, _), (.oidcAuthentication, .continueWithOIDC?):
            true
        default:
            false
        }
    }
    
    private func showStartScreen(fromState: State, applying provisioningParameters: AccountProvisioningParameters? = nil) {
        let parameters = AuthenticationStartScreenParameters(authenticationService: authenticationService,
                                                             provisioningParameters: provisioningParameters,
                                                             isBugReportServiceEnabled: bugReportService.isEnabled,
                                                             appSettings: appSettings,
                                                             userIndicatorController: userIndicatorController)
        let coordinator = AuthenticationStartScreenCoordinator(parameters: parameters)
        
        coordinator.actions
            .sink { [weak self] action in
                guard let self else { return }
                
                switch action {
                case .loginWithQR:
                    stateMachine.tryEvent(.loginWithQR)
                case .login:
                    stateMachine.tryEvent(.confirmServer(.login))
                case .register:
                    stateMachine.tryEvent(.confirmServer(.register))
                case .reportProblem:
                    stateMachine.tryEvent(.reportProblem)
                    
                case .loginDirectlyWithOIDC(let oidcData, let window):
                    stateMachine.tryEvent(.continueWithOIDC, userInfo: (oidcData, window))
                case .loginDirectlyWithPassword(let loginHint):
                    stateMachine.tryEvent(.continueWithPassword, userInfo: loginHint)
                }
            }
            .store(in: &cancellables)
        
        navigationStackCoordinator.setRootCoordinator(coordinator)
        
        if fromState == .initial {
            navigationRootCoordinator.setRootCoordinator(navigationStackCoordinator)
        }
    }
    
    // MARK: - Gua Phone-OIDC

    private func showPhoneEntryScreen(fromState: State) {
        let coordinator = PhoneEntryScreenCoordinator(parameters: .init(isLegacyAuthEnabled: appSettings.legacyAuthEnabled))
        
        coordinator.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .continue(let phoneNumber):
                    handlePhoneSubmission(phoneNumber: phoneNumber, coordinator: coordinator)
                case .signInWithPasskey:
                    handlePasskeySignIn(coordinator: coordinator)
                case .useLegacyAuth:
                    stateMachine.tryEvent(.useLegacyAuth)
                }
            }
            .store(in: &cancellables)
        
        phoneEntryScreenCoordinator = coordinator

        navigationStackCoordinator.setRootCoordinator(coordinator)
        
        if fromState == .initial {
            navigationRootCoordinator.setRootCoordinator(navigationStackCoordinator)
        }
    }
    
    private func handlePhoneSubmission(phoneNumber: String, coordinator: PhoneEntryScreenCoordinator) {
        guard !isHandlingPhoneSubmission, stateMachine.state == .phoneEntryScreen else { return }
        isHandlingPhoneSubmission = true
        coordinator.setSubmitting(true)
        Task { [weak self] in
            guard let self else { return }
            defer { endPhoneEntrySubmission(coordinator: coordinator) }
            
            // GUA FORK: configure with the resolver's base URL, not the server name: well-known
            // rediscovery is redundant and fails for http and localhost homeservers.
            let resolution: HomeserverResolution
            do {
                resolution = try await resolveHomeserver(forPhone: phoneNumber)
            } catch {
                MXLog.error("Resolver lookup failed: \(error)")
                let message = (error as? ResolverError)?.userFacingMessage ?? L10n.errorUnknown
                coordinator.displayError(message)
                return
            }

            let accountProvider = resolution.homeserver.baseURL
            let flow: AuthenticationFlow = resolution.exists ? .login : .register

            switch await authenticationService.configure(for: accountProvider, flow: flow) {
            case .success:
                break
            case .failure(let error):
                MXLog.error("Failed configuring OIDC login from phone hint: \(error)")
                // `AuthenticationServiceError` has no localized description, so show a generic error.
                coordinator.displayError(L10n.errorUnknown)
                return
            }
            
            guard authenticationService.homeserver.value.loginMode.supportsOIDCFlow else {
                coordinator.displayError(L10n.screenLoginErrorUnsupportedAuthentication)
                return
            }
            
            guard let window = appMediator.windowManager.mainWindow else {
                coordinator.displayError(L10n.errorUnknown)
                return
            }
            
            // GUA FORK: a flagged-on signup sends its genesis attach handle in the login hint.
            let loginHint: String
            do {
                loginHint = try await guaLoginHint(phoneNumber: phoneNumber, flow: flow)
            } catch {
                // This device meant to register a genesis and could not. Failing here is the point:
                // an account created without the genesis it intended is a silent bootstrap, which is
                // the failure mode ADM-008 decision 6 warns about, and it cannot be told apart later.
                MXLog.error("Failed preparing the account genesis for this signup: \(error)")
                coordinator.displayError(UntranslatedL10n.guaAccountGenesisSetupFailed)
                return
            }

            switch await authenticationService.urlForOIDCLogin(loginHint: loginHint) {
            case .success(let oidcData):
                stateMachine.tryEvent(.continueWithOIDC, userInfo: (oidcData, window))
            case .failure(let error):
                MXLog.error("Failed creating OIDC login URL from phone hint: \(error)")
                discardPendingAccountGenesis()
                coordinator.displayError(L10n.errorUnknown)
            }
        }
    }

    /// GUA FORK: the bare phone number unless this is a flagged-on signup on a deployment that supports genesis.
    /// Throws when a genesis was meant to be registered and could not be, which fails the signup.
    private func guaLoginHint(phoneNumber: String, flow: AuthenticationFlow) async throws -> String {
        // A resubmitted number starts a new signup, so whatever the last one registered is abandoned
        // here rather than left in the keychain.
        discardPendingAccountGenesis()

        // Sign-in never registers a genesis: only a new account gets one, so an existing user's path
        // through this method is the single `return` below, byte for byte what it was before.
        guard case .register = flow,
              let accountGenesisService,
              accountGenesisService.isEnabled else {
            return phoneNumber
        }

        switch try await accountGenesisService.registerGenesis() {
        case .disabled, .notSupportedByDeployment:
            return phoneNumber
        case .registered(let pending):
            pendingAccountGenesis = pending
            return accountGenesisService.loginHint(phoneNumber: phoneNumber, pending: pending)
        }
    }

    /// GUA FORK: call on every path that ends a signup without attaching. Only this pending value knows the
    /// accountId its keychain keys are filed under, so skipping it leaks two private keys.
    private func discardPendingAccountGenesis() {
        guard let pendingAccountGenesis else { return }
        accountGenesisService?.discard(pendingAccountGenesis)
        self.pendingAccountGenesis = nil
    }
    
    /// GUA FORK: uses the reserved `passkey` login hint because the sign-in page auto-submits a phone hint before
    /// offering the passkey. Signs in to the default account provider; accounts elsewhere must sign in by number.
    /// An identity-service without the passkey intent shows its page with no phone hint, so no server-version check is needed.
    private func handlePasskeySignIn(coordinator: PhoneEntryScreenCoordinator) {
        guard !isHandlingPhoneSubmission, stateMachine.state == .phoneEntryScreen else { return }
        isHandlingPhoneSubmission = true
        coordinator.setSubmitting(true)
        Task { [weak self] in
            guard let self else { return }
            defer { endPhoneEntrySubmission(coordinator: coordinator) }

            // GUA FORK: a passkey sign-in abandons any genesis a signup on this screen registered.
            discardPendingAccountGenesis()

            // A build with no Gua deployment configured (a development build without the injected
            // Secrets) has no default account provider, and `appSettings.accountProviders` then
            // still holds upstream's fallback. The phone path fails closed in that build because its
            // resolver is unconfigured (`ResolverError.notConfigured`); fail closed the same way,
            // with the same error, rather than send a passkey sign-in to a provider that is not ours.
            guard GuaDeployment.current.defaultAccountProvider != nil,
                  let accountProvider = appSettings.accountProviders.first, !accountProvider.isEmpty else {
                MXLog.error("Refusing passkey sign-in: no Gua deployment is configured for this build.")
                coordinator.displayError(ResolverError.notConfigured.userFacingMessage)
                return
            }

            switch await authenticationService.configure(for: accountProvider, flow: .login) {
            case .success:
                break
            case .failure(let error):
                MXLog.error("Failed configuring OIDC login for passkey sign-in: \(error)")
                coordinator.displayError(L10n.errorUnknown)
                return
            }

            guard authenticationService.homeserver.value.loginMode.supportsOIDCFlow else {
                coordinator.displayError(L10n.screenLoginErrorUnsupportedAuthentication)
                return
            }

            guard let window = appMediator.windowManager.mainWindow else {
                coordinator.displayError(L10n.errorUnknown)
                return
            }

            switch await authenticationService.urlForOIDCLogin(loginHint: AuthenticationService.passkeyLoginHint) {
            case .success(let oidcData):
                stateMachine.tryEvent(.continueWithOIDC, userInfo: (oidcData, window))
            case .failure(let error):
                MXLog.error("Failed creating OIDC login URL for passkey sign-in: \(error)")
                coordinator.displayError(L10n.errorUnknown)
            }
        }
    }

    /// The phone-entry screen stays disabled while the web authentication session is up and is
    /// enabled again when that session is cancelled.
    private func endPhoneEntrySubmission(coordinator: PhoneEntryScreenCoordinator) {
        if stateMachine.state != .oidcAuthentication {
            coordinator.setSubmitting(false)
        }
        isHandlingPhoneSubmission = false
    }

    /// GUA FORK: throws without a resolver rather than risk routing to the wrong MAS or homeserver.
    private func resolveHomeserver(forPhone phoneNumber: String) async throws -> HomeserverResolution {
        guard let resolverClient else { throw ResolverError.notConfigured }
        let resolution = try await resolverClient.resolve(phoneNumber: phoneNumber)
        resolverVerifier?.startVerification(of: resolution, phoneNumber: phoneNumber)
        return resolution
    }

    // MARK: - QR Code
    
    private func showQRCodeLoginScreen() {
        let coordinator = QRCodeLoginScreenCoordinator(parameters: .init(qrCodeLoginService: authenticationService,
                                                                         canSignInManually: appSettings.allowOtherAccountProviders, // No need to worry about provisioning links as we hide QR login.
                                                                         orientationManager: appMediator.windowManager,
                                                                         appMediator: appMediator))
        coordinator.actionsPublisher.sink { [weak self] action in
            guard let self else {
                return
            }
            switch action {
            case .signInManually:
                navigationStackCoordinator.setSheetCoordinator(nil)
                stateMachine.tryEvent(.cancelledLoginWithQR)
                stateMachine.tryEvent(.confirmServer(.login))
            case .cancel:
                navigationStackCoordinator.setSheetCoordinator(nil)
                stateMachine.tryEvent(.cancelledLoginWithQR)
            case .done(let userSession):
                navigationStackCoordinator.setSheetCoordinator(nil)
                // Since the qr code login flow includes verification
                appSettings.hasRunIdentityConfirmationOnboarding = true
                DispatchQueue.main.async {
                    self.stateMachine.tryEvent(.signedIn, userInfo: userSession)
                }
            }
        }
        .store(in: &cancellables)
        navigationStackCoordinator.setSheetCoordinator(coordinator) // Don't use the callback (interactive dismiss disabled), choose the event with the action.
    }
    
    // MARK: - Manual Authentication
    
    private func showServerConfirmationScreen(authenticationFlow: AuthenticationFlow) {
        // Reset the service back to the default homeserver before continuing. This ensures
        // we check that registration is supported if it was previously configured for login.
        authenticationService.reset()
        
        let parameters = ServerConfirmationScreenCoordinatorParameters(authenticationService: authenticationService,
                                                                       authenticationFlow: authenticationFlow,
                                                                       appSettings: appSettings,
                                                                       userIndicatorController: userIndicatorController)
        let coordinator = ServerConfirmationScreenCoordinator(parameters: parameters)
        
        coordinator.actions.sink { [weak self] action in
            guard let self else { return }
            
            switch action {
            case .continueWithOIDC(let oidcData, let window):
                stateMachine.tryEvent(.continueWithOIDC, userInfo: (oidcData, window))
            case .continueWithPassword:
                stateMachine.tryEvent(.continueWithPassword)
            case .changeServer:
                stateMachine.tryEvent(.changeServer(authenticationFlow))
            }
        }
        .store(in: &cancellables)
        
        navigationStackCoordinator.push(coordinator) { [weak self] in
            self?.stateMachine.tryEvent(.cancelledServerConfirmation)
        }
    }
    
    private func showServerSelectionScreen(authenticationFlow: AuthenticationFlow) {
        let navigationCoordinator = NavigationStackCoordinator()
        
        let parameters = ServerSelectionScreenCoordinatorParameters(authenticationService: authenticationService,
                                                                    authenticationFlow: authenticationFlow,
                                                                    appSettings: appSettings,
                                                                    userIndicatorController: userIndicatorController)
        let coordinator = ServerSelectionScreenCoordinator(parameters: parameters)
        
        coordinator.actions
            .sink { [weak self] action in
                guard let self else { return }
                
                switch action {
                case .updated:
                    navigationStackCoordinator.setSheetCoordinator(nil)
                case .dismiss:
                    navigationStackCoordinator.setSheetCoordinator(nil)
                }
            }
            .store(in: &cancellables)
        
        navigationCoordinator.setRootCoordinator(coordinator)
        navigationStackCoordinator.setSheetCoordinator(navigationCoordinator) { [weak self] in
            self?.stateMachine.tryEvent(.dismissedServerSelection)
        }
    }
    
    private func showOIDCAuthentication(oidcData: OIDCAuthorizationDataProxy, presentationAnchor: UIWindow, fromState: State) {
        let presenter = oidcPresenterFactory?(presentationAnchor) ?? OIDCAuthenticationPresenter(authenticationService: authenticationService,
                                                                                                 oidcRedirectURL: appSettings.oidcRedirectURL,
                                                                                                 presentationAnchor: presentationAnchor,
                                                                                                 userIndicatorController: userIndicatorController)
        oidcPresenter = presenter
        
        Task {
            switch await presenter.authenticate(using: oidcData) {
            case .success(let userSession):
                stateMachine.tryEvent(.signedIn, userInfo: userSession)
            case .failure:
                // GUA FORK: a cancelled or failed sign-in page never attaches the genesis.
                discardPendingAccountGenesis()
                stateMachine.tryEvent(.cancelledOIDCAuthentication(previousState: fromState))
                // Nothing more to do, the alerts are handled by the presenter.
            }
            oidcPresenter = nil
        }
    }
    
    private func showLoginScreen(loginHint: String?, fromState: State) {
        let parameters = LoginScreenCoordinatorParameters(authenticationService: authenticationService,
                                                          loginHint: loginHint,
                                                          userIndicatorController: userIndicatorController,
                                                          appSettings: appSettings,
                                                          analytics: analytics)
        let coordinator = LoginScreenCoordinator(parameters: parameters)
        
        coordinator.actions
            .sink { [weak self] action in
                guard let self else { return }

                switch action {
                case .signedIn(let userSession):
                    stateMachine.tryEvent(.signedIn, userInfo: userSession)
                case .configuredForOIDC:
                    // Pop back to the confirmation screen for OIDC login to continue.
                    navigationStackCoordinator.pop(animated: false)
                }
            }
            .store(in: &cancellables)
        
        navigationStackCoordinator.push(coordinator) { [weak self] in
            self?.stateMachine.tryEvent(.cancelledPasswordLogin(previousState: fromState))
        }
    }
    
    // MARK: - Bug Report
    
    private func startBugReportFlow() {
        let coordinator = BugReportFlowCoordinator(parameters: .init(presentationMode: .sheet(navigationStackCoordinator),
                                                                     userIndicatorController: userIndicatorController,
                                                                     bugReportService: bugReportService,
                                                                     userSession: nil))
        coordinator.actionsPublisher.sink { [weak self] action in
            switch action {
            case .complete:
                self?.stateMachine.tryEvent(.bugReportFlowComplete)
            }
        }
        .store(in: &cancellables)
        
        bugReportFlowCoordinator = coordinator
        coordinator.start()
    }
    
    // MARK: - Completion
        
    private func userHasSignedIn(userSession: UserSessionProtocol) {
        delegate?.authenticationFlowCoordinator(didLoginWithSession: userSession)
    }
}
