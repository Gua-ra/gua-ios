//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftState
import SwiftUI

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
    private let homeserverHistoryManager: HomeserverHistoryManager
    private let appHooks: AppHooks
    private let userIndicatorController: UserIndicatorControllerProtocol
    private let resolverClient: ResolverClientProtocol? // GUA FORK: phone -> homeserver routing
    private let accountGenesisService: AccountGenesisServiceProtocol? // GUA FORK: ADM-008 account genesis
    private let resolverVerifier: ResolverVerifying? // GUA FORK: report-only resolver verification
    private let usesPhoneLoginHint: Bool // GUA FORK
    private let oAuthPresenterFactory: ((UIWindow) -> OAuthAuthenticationPresenterProtocol)? // GUA FORK
    
    enum State: StateType {
        /// The state machine hasn't started.
        case initial
        
        /// GUA FORK: the default entry point.
        case phoneEntryScreen
        
        /// The initial screen shown when you first launch the app.
        case startScreen
        
        /// The screen used for the whole QR Code flow.
        case qrCodeLoginScreen
        
        /// The screen used to choose a server
        case serverSelectionScreen
        
        /// The screen to login with a password.
        case loginScreen
        
        /// The screen to report an error.
        case bugReportFlow
        /// The screen to toggle feature flags.
        case developerOptions
        
        /// The flow is complete.
        case complete
    }
    
    enum Event: EventType {
        /// The legacy flow is being started.
        case start
        /// Modify the flow using the provisioning parameters in the `userInfo`.
        case applyProvisioningParameters
        /// GUA FORK BEGIN: Gua phone-OAuth events
        case startPhoneAuth
        /// The user dropped into the legacy auth flow from the phone screen.
        case useLegacyAuth
        // GUA FORK END
        
        /// The user would like to login with a QR code.
        case loginWithQR
        /// Show the server confirmation screen.
        case selectServer(AuthenticationFlow)
        
        /// The QR login flow was aborted.
        case cancelledLoginWithQR
        /// The user aborted manual login.
        case cancelledServerSelection
        
        /// Show the screen to login with password (with the optional login hint in the `userInfo`).
        case continueWithPassword
        /// The password login was aborted.
        case cancelledPasswordLogin(previousState: State)
        
        /// The user encountered a problem.
        case reportProblem
        /// The user has finished reporting a problem (or viewing the logs).
        case bugReportFlowComplete
        
        /// The user wants to toggle a feature flag.
        case developerOptions
        /// The user finished toggling feature flags.
        case dismissedDeveloperOptions
        
        /// The user has successfully signed in. The new session can be found in the `userInfo`.
        case signedIn
    }
    
    private let stateMachine: StateMachine<State, Event>
    private var cancellables = Set<AnyCancellable>()
    
    private var oAuthPresenter: OAuthAuthenticationPresenterProtocol?
    
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
         appHooks: AppHooks,
         userIndicatorController: UserIndicatorControllerProtocol,
         resolverClient: ResolverClientProtocol? = nil,
         accountGenesisService: AccountGenesisServiceProtocol? = nil,
         resolverVerifier: ResolverVerifying? = nil,
         usesPhoneLoginHint: Bool = false,
         oAuthPresenterFactory: ((UIWindow) -> OAuthAuthenticationPresenterProtocol)? = nil) {
        self.authenticationService = authenticationService
        self.bugReportService = bugReportService
        self.navigationRootCoordinator = navigationRootCoordinator
        self.appMediator = appMediator
        self.appSettings = appSettings
        homeserverHistoryManager = HomeserverHistoryManager(appSettings: appSettings)
        self.appHooks = appHooks
        self.userIndicatorController = userIndicatorController
        self.resolverClient = resolverClient
        self.accountGenesisService = accountGenesisService
        self.resolverVerifier = resolverVerifier
        self.usesPhoneLoginHint = usesPhoneLoginHint
        self.oAuthPresenterFactory = oAuthPresenterFactory
        
        navigationStackCoordinator = NavigationStackCoordinator()
        
        stateMachine = .init(state: .initial)
        configureStateMachine()
    }
    
    /// GUA FORK: starts on the phone-entry screen instead of the start screen.
    private var usesPhoneFlow: Bool {
        usesPhoneLoginHint && !appSettings.legacyAuthEnabled
    }
    
    func start(animated: Bool) {
        if usesPhoneFlow {
            stateMachine.tryEvent(.startPhoneAuth)
        } else {
            stateMachine.tryEvent(.start)
        }
    }
    
    func handleAppRoute(_ appRoute: AppRoute, animated: Bool) {
        MXLog.info("Handling app route: \(appRoute)")
        
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
            
            // GUA FORK: a screen cleared above can still be on its way out.
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
        oAuthPresenter?.cancel() // Handle ongoing OAuth authentication first.
        
        switch stateMachine.state {
        case .initial, .startScreen, .phoneEntryScreen:
            break
        case .qrCodeLoginScreen:
            navigationStackCoordinator.setSheetCoordinator(nil)
            stateMachine.tryEvent(.cancelledLoginWithQR) // Needs to be handled manually.
        case .serverSelectionScreen:
            navigationStackCoordinator.popToRoot(animated: animated)
        case .loginScreen:
            navigationStackCoordinator.popToRoot(animated: animated)
        case .bugReportFlow:
            navigationStackCoordinator.setSheetCoordinator(nil)
        case .developerOptions:
            navigationStackCoordinator.setSheetCoordinator(nil)
        case .complete:
            fatalError()
        }
    }
    
    func handleOAuthCallbackURL(_ url: URL) {
        guard let oAuthPresenter else {
            MXLog.error("Failed to find an OAuth request in progress.")
            return
        }
        
        oAuthPresenter.handleUniversalLinkCallback(url)
    }
    
    // MARK: - Setup
    
    private func configureStateMachine() {
        stateMachine.addRoutes(event: .start, transitions: [.initial => .startScreen]) { [weak self] _ in
            self?.showStartScreen(fromState: .initial)
        }
        
        // Gua phone-OAuth flow
        
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
        
        stateMachine.addRoutes(event: .selectServer(.login), transitions: [.startScreen => .serverSelectionScreen]) { [weak self] _ in
            self?.showServerSelectionScreen(authenticationFlow: .login)
        }
        stateMachine.addRoutes(event: .selectServer(.register), transitions: [.startScreen => .serverSelectionScreen]) { [weak self] _ in
            self?.showServerSelectionScreen(authenticationFlow: .register)
        }
        stateMachine.addRoutes(event: .cancelledServerSelection, transitions: [.serverSelectionScreen => .startScreen])
        
        stateMachine.addRoutes(event: .continueWithPassword, transitions: [.serverSelectionScreen => .loginScreen,
                                                                           .startScreen => .loginScreen]) { [weak self] context in
            let loginHint = context.userInfo as? String
            self?.showLoginScreen(loginHint: loginHint, fromState: context.fromState)
        }
        stateMachine.addRoutes(event: .cancelledPasswordLogin(previousState: .serverSelectionScreen), transitions: [.loginScreen => .serverSelectionScreen])
        stateMachine.addRoutes(event: .cancelledPasswordLogin(previousState: .startScreen), transitions: [.loginScreen => .startScreen])
        
        // Bug Report
        
        stateMachine.addRoutes(event: .reportProblem, transitions: [.startScreen => .bugReportFlow]) { [weak self] _ in
            self?.startBugReportFlow()
        }
        stateMachine.addRoutes(event: .bugReportFlowComplete, transitions: [.bugReportFlow => .startScreen])
        
        // Developer Options
        
        stateMachine.addRoutes(event: .developerOptions, transitions: [.startScreen => .developerOptions]) { [weak self] _ in
            self?.showDeveloperOptionsScreen()
        }
        stateMachine.addRoutes(event: .dismissedDeveloperOptions, transitions: [.developerOptions => .startScreen])
        
        // Completion
        
        stateMachine.addRoutes(event: .signedIn, transitions: [.qrCodeLoginScreen => .complete,
                                                               .phoneEntryScreen => .complete, // Phone sign-in OAuth authentication
                                                               .serverSelectionScreen => .complete, // OAuth authentication
                                                               .startScreen => .complete, // Direct OAuth authentication
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
    
    /// Whether an event with no route from `state` is dropped instead of trapping.
    static func ignoresUnroutedEvent(_ event: Event?, from state: State) -> Bool {
        switch (state, event) {
        case (.complete, _):
            true
        default:
            false
        }
    }
    
    private func showStartScreen(fromState: State, applying provisioningParameters: AccountProvisioningParameters? = nil) {
        let mediaProvider = authenticationService.classicAppAccount.map { account in
            MediaProvider(mediaLoader: ClassicAppMediaLoader(classicAppAccount: account),
                          imageCache: .onlyInMemory,
                          homeserverReachabilityPublisher: appMediator.networkMonitor.reachabilityPublisher.map(HomeserverReachability.init)) // Close enough approximation
        }
        
        let parameters = AuthenticationStartScreenParameters(authenticationService: authenticationService,
                                                             provisioningParameters: provisioningParameters,
                                                             isBugReportServiceEnabled: bugReportService.isEnabled,
                                                             appMediator: appMediator,
                                                             appSettings: appSettings,
                                                             mediaProvider: mediaProvider,
                                                             userIndicatorController: userIndicatorController)
        let coordinator = AuthenticationStartScreenCoordinator(parameters: parameters)
        
        coordinator.actions
            .sink { [weak self] action in
                guard let self else { return }
                
                switch action {
                case .loginWithQR:
                    stateMachine.tryEvent(.loginWithQR)
                case .login:
                    stateMachine.tryEvent(.selectServer(.login))
                case .register:
                    stateMachine.tryEvent(.selectServer(.register))
                    
                case .loginDirectlyWithOAuth(let oAuthData, let window):
                    showOAuthAuthentication(oAuthData: oAuthData, presentationAnchor: window)
                case .loginDirectlyWithPassword(let loginHint):
                    stateMachine.tryEvent(.continueWithPassword, userInfo: loginHint)
                    
                case .reportProblem:
                    stateMachine.tryEvent(.reportProblem)
                case .developerOptions:
                    stateMachine.tryEvent(.developerOptions)
                }
            }
            .store(in: &cancellables)
        
        navigationStackCoordinator.setRootCoordinator(coordinator)
        
        if fromState == .initial {
            navigationRootCoordinator.setRootCoordinator(navigationStackCoordinator)
        }
    }
    
    // MARK: - Gua Phone-OAuth
    
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
        guard !isHandlingPhoneSubmission, oAuthPresenter == nil, stateMachine.state == .phoneEntryScreen else { return }
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
                MXLog.error("Failed configuring OAuth login from phone hint: \(error)")
                // `AuthenticationServiceError` has no localized description, so show a generic error.
                coordinator.displayError(L10n.errorUnknown)
                return
            }
            
            guard authenticationService.homeserver.value.loginMode.supportsOAuthFlow else {
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
            
            switch await authenticationService.urlForOAuthLogin(loginHint: loginHint) {
            case .success(let oAuthData):
                showOAuthAuthentication(oAuthData: oAuthData, presentationAnchor: window)
            case .failure(let error):
                MXLog.error("Failed creating OAuth login URL from phone hint: \(error)")
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
        guard !isHandlingPhoneSubmission, oAuthPresenter == nil, stateMachine.state == .phoneEntryScreen else { return }
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
                  let accountProvider = appSettings.accountProviders.first?.serverNameOrBaseURL, !accountProvider.isEmpty else {
                MXLog.error("Refusing passkey sign-in: no Gua deployment is configured for this build.")
                coordinator.displayError(ResolverError.notConfigured.userFacingMessage)
                return
            }
            
            switch await authenticationService.configure(for: accountProvider, flow: .login) {
            case .success:
                break
            case .failure(let error):
                MXLog.error("Failed configuring OAuth login for passkey sign-in: \(error)")
                coordinator.displayError(L10n.errorUnknown)
                return
            }
            
            guard authenticationService.homeserver.value.loginMode.supportsOAuthFlow else {
                coordinator.displayError(L10n.screenLoginErrorUnsupportedAuthentication)
                return
            }
            
            guard let window = appMediator.windowManager.mainWindow else {
                coordinator.displayError(L10n.errorUnknown)
                return
            }
            
            switch await authenticationService.urlForOAuthLogin(loginHint: AuthenticationService.passkeyLoginHint) {
            case .success(let oAuthData):
                showOAuthAuthentication(oAuthData: oAuthData, presentationAnchor: window)
            case .failure(let error):
                MXLog.error("Failed creating OAuth login URL for passkey sign-in: \(error)")
                coordinator.displayError(L10n.errorUnknown)
            }
        }
    }
    
    /// The phone-entry screen stays disabled while the web authentication session is up and is
    /// enabled again when that session is cancelled.
    private func endPhoneEntrySubmission(coordinator: PhoneEntryScreenCoordinator) {
        if oAuthPresenter == nil {
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
        let stackCoordinator = NavigationStackCoordinator()
        let coordinator = QRCodeLoginScreenCoordinator(parameters: .init(mode: .login(authenticationService),
                                                                         canSignInManually: appSettings.allowOtherAccountProviders, // No need to worry about provisioning links as we hide QR login.
                                                                         orientationManager: appMediator.windowManager,
                                                                         appMediator: appMediator))
        coordinator.actionsPublisher.sink { [weak self] action in
            guard let self else {
                return
            }
            switch action {
            case .startOver:
                fatalError("QR code login shouldn't request to start over as it's handled within the screen.")
            case .requestOAuthAuthorisation, .linkedDevice:
                fatalError("QR code login shouldn't request an OAuth flow or link a device.")
            case .signInManually:
                navigationStackCoordinator.setSheetCoordinator(nil)
                stateMachine.tryEvent(.cancelledLoginWithQR)
                stateMachine.tryEvent(.selectServer(.login))
            case .signedIn(let userSession):
                navigationStackCoordinator.setSheetCoordinator(nil)
                DispatchQueue.main.async {
                    self.stateMachine.tryEvent(.signedIn, userInfo: userSession)
                }
            case .cancel:
                navigationStackCoordinator.setSheetCoordinator(nil)
                stateMachine.tryEvent(.cancelledLoginWithQR)
            }
        }
        .store(in: &cancellables)
        
        stackCoordinator.setRootCoordinator(coordinator)
        navigationStackCoordinator.setSheetCoordinator(stackCoordinator) // Don't use the callback (interactive dismiss disabled), choose the event with the action.
    }
    
    // MARK: - Manual Authentication
    
    private func showServerSelectionScreen(authenticationFlow: AuthenticationFlow) {
        // Reset the service back to the default homeserver before continuing. This ensures
        // we check that registration is supported if it was previously configured for login.
        authenticationService.reset()
        
        let parameters = ServerSelectionScreenCoordinatorParameters(authenticationService: authenticationService,
                                                                    authenticationFlow: authenticationFlow,
                                                                    appSettings: appSettings,
                                                                    homeserverHistoryManager: homeserverHistoryManager,
                                                                    userIndicatorController: userIndicatorController)
        let coordinator = ServerSelectionScreenCoordinator(parameters: parameters)
        
        coordinator.actions
            .sink { [weak self] action in
                guard let self else { return }
                
                switch action {
                case .continueWithOAuth(let oAuthData, let window):
                    showOAuthAuthentication(oAuthData: oAuthData, presentationAnchor: window)
                case .continueWithPassword:
                    stateMachine.tryEvent(.continueWithPassword)
                }
            }
            .store(in: &cancellables)
        
        navigationStackCoordinator.push(coordinator) { [weak self] in
            self?.stateMachine.tryEvent(.cancelledServerSelection)
        }
    }
    
    /// **Note:** We have intentionally excluded this presentation from the state machine as it doesn't mutate our navigation stack and there
    /// isn't a robust way to detect why the user returned to the app when the MAS URL directly opens an external app for authentication without
    /// presenting a web authentication session.
    private func showOAuthAuthentication(oAuthData: OAuthAuthorizationDataProxy, presentationAnchor: UIWindow) {
        let presenter = oAuthPresenterFactory?(presentationAnchor) ?? OAuthAuthenticationPresenter(authenticationService: authenticationService,
                                                                                                   redirectURL: appSettings.oAuthRedirectURL,
                                                                                                   presentationAnchor: presentationAnchor,
                                                                                                   appMediator: appMediator,
                                                                                                   presenterHook: appHooks.oAuthAuthenticationPresenterHook,
                                                                                                   userIndicatorController: userIndicatorController)
        oAuthPresenter = presenter
        
        Task {
            switch await presenter.authenticate(using: oAuthData) {
            case .success(let userSession):
                stateMachine.tryEvent(.signedIn, userInfo: userSession)
            case .failure:
                // GUA FORK: a cancelled or failed sign-in page never attaches the genesis.
                discardPendingAccountGenesis()
                phoneEntryScreenCoordinator?.setSubmitting(false)
                // Nothing more to do, any alerts will be handled by the presenter.
            }
            oAuthPresenter = nil
        }
    }
    
    private func showLoginScreen(loginHint: String?, fromState: State) {
        let parameters = LoginScreenCoordinatorParameters(authenticationService: authenticationService,
                                                          loginHint: loginHint,
                                                          userIndicatorController: userIndicatorController,
                                                          appSettings: appSettings)
        let coordinator = LoginScreenCoordinator(parameters: parameters)
        
        coordinator.actions
            .sink { [weak self] action in
                guard let self else { return }
                
                switch action {
                case .signedIn(let userSession):
                    stateMachine.tryEvent(.signedIn, userInfo: userSession)
                case .configuredForOAuth:
                    // Pop back to the confirmation screen for OAuth login to continue.
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
    
    // MARK: - Developer Options
    
    private func showDeveloperOptionsScreen() {
        let stackCoordinator = NavigationStackCoordinator()
        let coordinator = DeveloperOptionsScreenCoordinator(appSettings: appSettings,
                                                            screenHook: appHooks.developerOptionsScreenHook,
                                                            clientProxy: nil)
        coordinator.actions
            .sink { action in
                switch action {
                case .clearCache:
                    break // Not sent when clientProxy == nil
                }
            }
            .store(in: &cancellables)
        
        stackCoordinator.setRootCoordinator(coordinator)
        navigationStackCoordinator.setSheetCoordinator(stackCoordinator) { [weak self] in
            self?.stateMachine.tryEvent(.dismissedDeveloperOptions)
        }
    }
    
    // MARK: - Completion
    
    private func userHasSignedIn(userSession: UserSessionProtocol) {
        delegate?.authenticationFlowCoordinator(didLoginWithSession: userSession)
        
        let newAccountProvider = authenticationService.homeserver.value.accountProvider
        homeserverHistoryManager.addServerToList(newAccountProvider.serverNameOrBaseURL)
    }
}
