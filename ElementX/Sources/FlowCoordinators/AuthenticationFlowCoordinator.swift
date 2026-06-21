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
    private let appHooks: AppHooks
    private let analytics: AnalyticsServiceProtocol
    private let userIndicatorController: UserIndicatorControllerProtocol

    // GUA FORK: phone-OTP onboarding dependencies.
    private let identityServiceClient: IdentityServiceClientProtocol?
    private let resolverClient: ResolverClientProtocol? // phone -> homeserver routing
    private let usesPhoneLoginHint: Bool

    enum State: StateType {
        /// The state machine hasn't started.
        case initial
        
        /// The initial screen shown when you first launch the app.
        case startScreen
        
        /// The screen used for the whole QR Code flow.
        case qrCodeLoginScreen
        
        /// The screen to continue authentication with the current server.
        case serverConfirmationScreen
        /// The screen to choose a different server.
        case serverSelectionScreen
        /// The screen to login with a password.
        case loginScreen
        
        /// The screen to report an error.
        case bugReportFlow
        /// The screen to toggle feature flags.
        case developerOptions

        // GUA FORK: phone-OTP-PIN onboarding states.
        case phoneEntryScreen
        case otpEntryScreen
        case pinChallengeScreen
        case profileSetupScreen
        case pinSetupScreen

        /// The flow is complete.
        case complete
    }
    
    enum Event: EventType {
        /// The flow is being started.
        case start
        
        /// Modify the flow using the provisioning parameters in the `userInfo`.
        case applyProvisioningParameters
        
        /// The user would like to login with a QR code.
        case loginWithQR
        /// Show the server confirmation screen.
        case confirmServer(AuthenticationFlow)
        
        /// The QR login flow was aborted.
        case cancelledLoginWithQR
        /// The user aborted manual login.
        case cancelledServerConfirmation
        
        /// The user would like to enter a different server.
        case changeServer(AuthenticationFlow)
        /// The user is no longer selecting a server.
        case dismissedServerSelection
        
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

        // GUA FORK: phone-OTP-PIN onboarding events. Dynamic payloads are passed via `userInfo`.
        case startPhoneAuth
        case continueWithPhone
        case useLegacyAuth
        case cancelledOTPEntry
        case needsPinChallenge
        case cancelledPinChallenge
        case needsProfileSetup
        case cancelledProfileSetup
        case offerPinSetup
        case cancelledPinSetup
        case usernameTakenDuringSignup
    }

    // GUA FORK: payloads carried through the phone-OTP-PIN onboarding state machine.
    private struct PhoneEntryContext { let phoneNumber: String }
    private struct OTPEntryContext { let phoneNumber: String; let resolution: HomeserverResolution }
    private struct PinChallengeContext { let phoneNumber: String; let challengeToken: String }
    private struct ProfileSetupContext { let phoneNumber: String; let signupToken: String }
    private struct PendingSignupContext { let signupToken: String; let phoneNumber: String; let username: String; let displayName: String }
    
    private let stateMachine: StateMachine<State, Event>
    private var cancellables = Set<AnyCancellable>()
    
    private var oAuthPresenter: OAuthAuthenticationPresenter?

    // periphery:ignore - retaining purpose
    private var bugReportFlowCoordinator: BugReportFlowCoordinator?

    // GUA FORK: retained phone-OTP-PIN onboarding child coordinators.
    // periphery:ignore - retaining purpose
    private var phoneEntryScreenCoordinator: PhoneEntryScreenCoordinator?
    // periphery:ignore - retaining purpose
    private var otpEntryScreenCoordinator: OtpEntryScreenCoordinator?
    // periphery:ignore - retaining purpose
    private var pinChallengeScreenCoordinator: PinChallengeScreenCoordinator?
    // periphery:ignore - retaining purpose
    private var profileSetupScreenCoordinator: ProfileSetupScreenCoordinator?
    // periphery:ignore - retaining purpose
    private var pinSetupScreenCoordinator: PinSetupScreenCoordinator?

    // GUA FORK: re-entrancy guards for the async onboarding steps.
    private var isHandlingPhoneSubmission = false
    private var isHandlingOTPVerification = false
    private var isHandlingProfileSubmission = false
    private var isHandlingPinVerification = false
    private var isHandlingPinSetup = false

    // GUA FORK: payload retained between the OTP step and the PIN/profile follow-ups.
    private var pendingPinChallengeContext: PinChallengeContext?
    private var pendingProfileSetupContext: ProfileSetupContext?
    private var pendingSignupContext: PendingSignupContext?
    private var pendingOTPContext: OTPEntryContext?

    weak var delegate: AuthenticationFlowCoordinatorDelegate?
    
    init(authenticationService: AuthenticationServiceProtocol,
         bugReportService: BugReportServiceProtocol,
         navigationRootCoordinator: NavigationRootCoordinator,
         appMediator: AppMediatorProtocol,
         appSettings: AppSettings,
         appHooks: AppHooks,
         analytics: AnalyticsServiceProtocol,
         userIndicatorController: UserIndicatorControllerProtocol,
         identityServiceClient: IdentityServiceClientProtocol? = nil,
         resolverClient: ResolverClientProtocol? = nil,
         usesPhoneLoginHint: Bool = false) {
        self.authenticationService = authenticationService
        self.bugReportService = bugReportService
        self.navigationRootCoordinator = navigationRootCoordinator
        self.appMediator = appMediator
        self.appSettings = appSettings
        self.appHooks = appHooks
        self.analytics = analytics
        self.userIndicatorController = userIndicatorController
        // GUA FORK: fall back to the default Gua identity service when one isn't injected
        // (AppCoordinator passes nil; tests inject a mock).
        self.identityServiceClient = identityServiceClient ?? IdentityServiceClient()
        self.resolverClient = resolverClient
        self.usesPhoneLoginHint = usesPhoneLoginHint

        navigationStackCoordinator = NavigationStackCoordinator()

        stateMachine = .init(state: .initial)
        configureStateMachine()
    }

    func start(animated: Bool) {
        // GUA FORK: phone-OTP onboarding is the default entry point unless legacy auth is enabled.
        if usesPhoneLoginHint, !appSettings.legacyAuthEnabled {
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
            
            if stateMachine.state != .startScreen {
                clearRoute(animated: animated)
            }
            
            stateMachine.tryEvent(.applyProvisioningParameters, userInfo: provisioningParameters)
        default:
            fatalError()
        }
    }
    
    func clearRoute(animated: Bool) {
        oAuthPresenter?.cancel() // Handle ongoing OAuth authentication first.
        
        switch stateMachine.state {
        case .initial, .startScreen:
            break
        case .qrCodeLoginScreen:
            navigationStackCoordinator.setSheetCoordinator(nil)
            stateMachine.tryEvent(.cancelledLoginWithQR) // Needs to be handled manually.
        case .serverConfirmationScreen:
            navigationStackCoordinator.popToRoot(animated: animated)
        case .serverSelectionScreen:
            navigationStackCoordinator.setSheetCoordinator(nil)
            navigationStackCoordinator.popToRoot(animated: animated)
        case .loginScreen:
            navigationStackCoordinator.popToRoot(animated: animated)
        case .bugReportFlow:
            navigationStackCoordinator.setSheetCoordinator(nil)
        case .developerOptions:
            navigationStackCoordinator.setSheetCoordinator(nil)
        // GUA FORK: phone-OTP-PIN onboarding states.
        case .phoneEntryScreen:
            break
        case .otpEntryScreen:
            navigationStackCoordinator.popToRoot(animated: animated)
            stateMachine.tryEvent(.cancelledOTPEntry)
        case .pinChallengeScreen:
            navigationStackCoordinator.pop(animated: animated)
            stateMachine.tryEvent(.cancelledPinChallenge)
        case .profileSetupScreen:
            navigationStackCoordinator.pop(animated: animated)
            stateMachine.tryEvent(.cancelledProfileSetup)
        case .pinSetupScreen:
            break // Handled by the in-screen "Not now".
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
        
        // Developer Options
        
        stateMachine.addRoutes(event: .developerOptions, transitions: [.startScreen => .developerOptions]) { [weak self] _ in
            self?.showDeveloperOptionsScreen()
        }
        stateMachine.addRoutes(event: .dismissedDeveloperOptions, transitions: [.developerOptions => .startScreen])
        
        // Completion
        
        stateMachine.addRoutes(event: .signedIn, transitions: [.qrCodeLoginScreen => .complete,
                                                               .serverConfirmationScreen => .complete, // OAuth authentication
                                                               .startScreen => .complete, // Direct OAuth authentication
                                                               .loginScreen => .complete,
                                                               // GUA FORK: phone-OTP-PIN terminal states.
                                                               .phoneEntryScreen => .complete,
                                                               .otpEntryScreen => .complete,
                                                               .pinChallengeScreen => .complete,
                                                               .profileSetupScreen => .complete,
                                                               .pinSetupScreen => .complete]) { [weak self] context in
            guard let userSession = context.userInfo as? UserSessionProtocol else { fatalError("The user session wasn't included in the context") }
            self?.userHasSignedIn(userSession: userSession)
        }

        configureGuaPhoneAuthStateMachine()
        
        // Logging
        
        stateMachine.addAnyHandler(.any => .any) { context in
            MXLog.info("Transitioning from `\(context.fromState)` to `\(context.toState)` with event `\(String(describing: context.event))`.")
        }
        
        // Unhandled
        
        stateMachine.addErrorHandler { context in
            switch (context.fromState, context.toState) {
            case (.complete, .complete):
                break // Ignore all events triggered by
            default:
                fatalError("Unexpected transition: \(context)")
            }
        }
    }
    
    // MARK: - Gua Phone-OTP state machine

    // GUA FORK: wires the phone -> OTP -> (PIN challenge | profile + PIN setup) onboarding.
    private func configureGuaPhoneAuthStateMachine() {
        stateMachine.addRoutes(event: .startPhoneAuth, transitions: [.initial => .phoneEntryScreen]) { [weak self] _ in
            self?.showPhoneEntryScreen(fromState: .initial)
        }

        stateMachine.addRoutes(event: .useLegacyAuth, transitions: [.phoneEntryScreen => .startScreen]) { [weak self] _ in
            self?.showStartScreen(fromState: .phoneEntryScreen)
        }

        stateMachine.addRoutes(event: .continueWithPhone, transitions: [.phoneEntryScreen => .otpEntryScreen]) { [weak self] context in
            guard let otpContext = context.userInfo as? OTPEntryContext else { fatalError("Missing OTP context") }
            self?.showOTPEntryScreen(phoneNumber: otpContext.phoneNumber)
        }

        stateMachine.addRoutes(event: .cancelledOTPEntry, transitions: [.otpEntryScreen => .phoneEntryScreen]) { [weak self] _ in
            self?.showPhoneEntryScreen(fromState: .otpEntryScreen)
        }

        stateMachine.addRoutes(event: .needsPinChallenge, transitions: [.otpEntryScreen => .pinChallengeScreen]) { [weak self] context in
            guard let pinContext = context.userInfo as? PinChallengeContext else { fatalError("Missing PIN challenge context") }
            self?.showPinChallengeScreen(context: pinContext)
        }

        stateMachine.addRoutes(event: .cancelledPinChallenge, transitions: [.pinChallengeScreen => .otpEntryScreen]) { [weak self] _ in
            guard let phoneNumber = self?.pendingOTPContext?.phoneNumber else { return }
            self?.showOTPEntryScreen(phoneNumber: phoneNumber)
        }

        stateMachine.addRoutes(event: .needsProfileSetup, transitions: [.otpEntryScreen => .profileSetupScreen]) { [weak self] context in
            guard let profileContext = context.userInfo as? ProfileSetupContext else { fatalError("Missing profile setup context") }
            self?.showProfileSetupScreen(context: profileContext)
        }

        stateMachine.addRoutes(event: .cancelledProfileSetup, transitions: [.profileSetupScreen => .otpEntryScreen]) { [weak self] _ in
            guard let phoneNumber = self?.pendingOTPContext?.phoneNumber else { return }
            self?.showOTPEntryScreen(phoneNumber: phoneNumber)
        }

        stateMachine.addRoutes(event: .offerPinSetup, transitions: [.profileSetupScreen => .pinSetupScreen]) { [weak self] context in
            guard let pendingContext = context.userInfo as? PendingSignupContext else { fatalError("Missing pending signup context") }
            self?.showPinSetupScreen(context: pendingContext)
        }

        stateMachine.addRoutes(event: .cancelledPinSetup, transitions: [.pinSetupScreen => .phoneEntryScreen]) { [weak self] _ in
            self?.showPhoneEntryScreen(fromState: .pinSetupScreen)
        }

        stateMachine.addRoutes(event: .usernameTakenDuringSignup, transitions: [.pinSetupScreen => .profileSetupScreen]) { [weak self] _ in
            // The signup token survives because the backend only consumes it on success.
            self?.profileSetupScreenCoordinator?.displayError(IdentityServiceError.usernameTaken.localizedDescription)
        }
    }

    // MARK: - Gua Phone-OTP

    // GUA FORK
    private func showPhoneEntryScreen(fromState: State) {
        let parameters = PhoneEntryScreenCoordinatorParameters(isLegacyAuthEnabled: appSettings.legacyAuthEnabled)
        let coordinator = PhoneEntryScreenCoordinator(parameters: parameters)

        coordinator.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .continue(let phoneNumber):
                    handlePhoneSubmission(phoneNumber: phoneNumber, coordinator: coordinator)
                case .useLegacyAuth:
                    stateMachine.tryEvent(.useLegacyAuth)
                }
            }
            .store(in: &cancellables)

        phoneEntryScreenCoordinator = coordinator
        coordinator.start()

        navigationStackCoordinator.setRootCoordinator(coordinator)

        if fromState == .initial {
            navigationRootCoordinator.setRootCoordinator(navigationStackCoordinator)
        }
    }

    // GUA FORK
    private func handlePhoneSubmission(phoneNumber: String, coordinator: PhoneEntryScreenCoordinator) {
        guard !isHandlingPhoneSubmission else { return }
        isHandlingPhoneSubmission = true
        coordinator.setSubmitting(true)

        Task {
            defer {
                isHandlingPhoneSubmission = false
                coordinator.setSubmitting(false)
            }

            guard let identityServiceClient else {
                coordinator.displayError(L10n.errorUnknown)
                return
            }

            do {
                let resolution = try await resolveHomeserver(forPhone: phoneNumber)
                try await identityServiceClient.sendOTP(phone: phoneNumber, language: nil)
                let otpContext = OTPEntryContext(phoneNumber: phoneNumber, resolution: resolution)
                pendingOTPContext = otpContext
                stateMachine.tryEvent(.continueWithPhone, userInfo: otpContext)
            } catch {
                MXLog.error("Failed starting phone authentication: \(error)")
                coordinator.displayError((error as? LocalizedError)?.errorDescription ?? L10n.errorUnknown)
            }
        }
    }

    // GUA FORK
    private func resolveHomeserver(forPhone phoneNumber: String) async throws -> HomeserverResolution {
        guard let resolverClient else { throw ResolverError.notConfigured }
        return try await resolverClient.resolve(phoneNumber: phoneNumber)
    }

    // GUA FORK
    private func showOTPEntryScreen(phoneNumber: String) {
        let parameters = OtpEntryScreenCoordinatorParameters(phoneNumber: phoneNumber)
        let coordinator = OtpEntryScreenCoordinator(parameters: parameters)

        coordinator.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .verify(let code):
                    handleOTPVerification(code: code, phoneNumber: phoneNumber, coordinator: coordinator)
                case .resend:
                    handleOTPResend(phoneNumber: phoneNumber, coordinator: coordinator)
                case .changePhone:
                    // Fire the cancel event before popping; SwiftUI onDismiss runs synchronously during pop.
                    if stateMachine.state == .otpEntryScreen {
                        stateMachine.tryEvent(.cancelledOTPEntry)
                    }
                }
            }
            .store(in: &cancellables)

        otpEntryScreenCoordinator = coordinator
        coordinator.start()

        navigationStackCoordinator.push(coordinator) { [weak self] in
            guard let self, stateMachine.state == .otpEntryScreen else { return }
            stateMachine.tryEvent(.cancelledOTPEntry)
        }
    }

    // GUA FORK
    private func handleOTPVerification(code: String, phoneNumber: String, coordinator: OtpEntryScreenCoordinator) {
        guard !isHandlingOTPVerification else { return }
        isHandlingOTPVerification = true
        coordinator.setVerifying(true)

        Task {
            defer {
                isHandlingOTPVerification = false
                coordinator.setVerifying(false)
            }

            guard let identityServiceClient else {
                coordinator.displayError(L10n.errorUnknown)
                return
            }

            do {
                let outcome = try await identityServiceClient.verifyOTP(phone: phoneNumber,
                                                                        code: code,
                                                                        pin: nil,
                                                                        device: .current)
                switch outcome {
                case .newUser(let signupToken):
                    let context = ProfileSetupContext(phoneNumber: phoneNumber, signupToken: signupToken)
                    pendingProfileSetupContext = context
                    stateMachine.tryEvent(.needsProfileSetup, userInfo: context)
                case .pinRequired(let challengeToken):
                    let context = PinChallengeContext(phoneNumber: phoneNumber, challengeToken: challengeToken)
                    pendingPinChallengeContext = context
                    stateMachine.tryEvent(.needsPinChallenge, userInfo: context)
                case .existingUser(let session):
                    await signIn(with: session, fromCoordinatorError: coordinator.displayError)
                }
            } catch {
                MXLog.error("Failed verifying OTP: \(error)")
                coordinator.displayError((error as? LocalizedError)?.errorDescription ?? L10n.errorUnknown)
            }
        }
    }

    // GUA FORK
    private func handleOTPResend(phoneNumber: String, coordinator: OtpEntryScreenCoordinator) {
        Task {
            guard let identityServiceClient else { return }
            do {
                try await identityServiceClient.sendOTP(phone: phoneNumber, language: nil)
                coordinator.resetForResend()
            } catch {
                MXLog.error("Failed resending OTP: \(error)")
                coordinator.displayError((error as? LocalizedError)?.errorDescription ?? L10n.errorUnknown)
            }
        }
    }

    // GUA FORK: restores the Matrix session minted by the identity service and completes sign-in.
    private func signIn(with session: IdentityServiceMatrixSession, fromCoordinatorError displayError: @MainActor @escaping (String) -> Void) async {
        switch await authenticationService.loginWithExistingMatrixSession(accessToken: session.accessToken,
                                                                          refreshToken: nil,
                                                                          userId: session.userId,
                                                                          deviceId: session.deviceId,
                                                                          homeserverUrl: session.baseUrl) {
        case .success(let userSession):
            appSettings.hasRunIdentityConfirmationOnboarding = true
            stateMachine.tryEvent(.signedIn, userInfo: userSession)
        case .failure:
            displayError(L10n.errorUnknown)
        }
    }

    // MARK: - Profile Setup (new user signup)

    // GUA FORK
    private func showProfileSetupScreen(context: ProfileSetupContext) {
        let parameters = ProfileSetupScreenCoordinatorParameters(phoneNumber: context.phoneNumber)
        let coordinator = ProfileSetupScreenCoordinator(parameters: parameters)

        if let identityServiceClient {
            coordinator.setUsernameAvailabilityChecker { username in
                try await identityServiceClient.checkUsernameAvailability(username)
            }
        }

        coordinator.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .complete(let username, let displayName):
                    let pending = PendingSignupContext(signupToken: context.signupToken,
                                                       phoneNumber: context.phoneNumber,
                                                       username: username,
                                                       displayName: displayName)
                    pendingSignupContext = pending
                    stateMachine.tryEvent(.offerPinSetup, userInfo: pending)
                case .cancel:
                    if stateMachine.state == .profileSetupScreen {
                        stateMachine.tryEvent(.cancelledProfileSetup)
                    }
                }
            }
            .store(in: &cancellables)

        profileSetupScreenCoordinator = coordinator
        coordinator.start()

        navigationStackCoordinator.push(coordinator) { [weak self] in
            guard let self, stateMachine.state == .profileSetupScreen else { return }
            stateMachine.tryEvent(.cancelledProfileSetup)
        }
    }

    // GUA FORK
    private func showPinSetupScreen(context: PendingSignupContext) {
        let coordinator = PinSetupScreenCoordinator()

        coordinator.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .complete(let pin):
                    handleSignupCompletion(context: context, pin: pin, coordinator: coordinator)
                case .skip:
                    handleSignupCompletion(context: context, pin: nil, coordinator: coordinator)
                }
            }
            .store(in: &cancellables)

        pinSetupScreenCoordinator = coordinator
        coordinator.start()

        navigationStackCoordinator.push(coordinator)
    }

    // GUA FORK
    private func handleSignupCompletion(context: PendingSignupContext, pin: String?, coordinator: PinSetupScreenCoordinator) {
        guard !isHandlingPinSetup else { return }
        isHandlingPinSetup = true
        coordinator.setSubmitting(true)

        Task {
            defer {
                isHandlingPinSetup = false
                coordinator.setSubmitting(false)
            }

            guard let identityServiceClient else {
                coordinator.displayError(L10n.errorUnknown)
                return
            }

            do {
                let session = try await identityServiceClient.completeSignup(signupToken: context.signupToken,
                                                                             username: context.username,
                                                                             displayName: context.displayName,
                                                                             pin: pin,
                                                                             device: .current)
                await signIn(with: session, fromCoordinatorError: coordinator.displayError)
            } catch IdentityServiceError.usernameTaken {
                stateMachine.tryEvent(.usernameTakenDuringSignup)
            } catch IdentityServiceError.invalidSignupToken {
                userIndicatorController.submitIndicator(UserIndicator(title: IdentityServiceError.invalidSignupToken.localizedDescription))
                navigationStackCoordinator.popToRoot(animated: true)
            } catch IdentityServiceError.phoneAlreadyLinked {
                userIndicatorController.submitIndicator(UserIndicator(title: IdentityServiceError.phoneAlreadyLinked.localizedDescription))
                navigationStackCoordinator.popToRoot(animated: true)
            } catch {
                MXLog.error("Failed completing signup: \(error)")
                coordinator.displayError((error as? LocalizedError)?.errorDescription ?? L10n.errorUnknown)
            }
        }
    }

    // MARK: - PIN Challenge (returning user with two-step verification)

    // GUA FORK
    private func showPinChallengeScreen(context: PinChallengeContext) {
        let parameters = PinChallengeScreenCoordinatorParameters(phoneNumber: context.phoneNumber)
        let coordinator = PinChallengeScreenCoordinator(parameters: parameters)

        coordinator.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .verify(let pin):
                    handlePinVerification(pin: pin, context: context, coordinator: coordinator)
                case .forgotPin:
                    coordinator.displayError(L10n.errorUnknown)
                case .cancel:
                    if stateMachine.state == .pinChallengeScreen {
                        stateMachine.tryEvent(.cancelledPinChallenge)
                    }
                }
            }
            .store(in: &cancellables)

        pinChallengeScreenCoordinator = coordinator
        coordinator.start()

        navigationStackCoordinator.push(coordinator) { [weak self] in
            guard let self, stateMachine.state == .pinChallengeScreen else { return }
            stateMachine.tryEvent(.cancelledPinChallenge)
        }
    }

    // GUA FORK
    private func handlePinVerification(pin: String, context: PinChallengeContext, coordinator: PinChallengeScreenCoordinator) {
        guard !isHandlingPinVerification else { return }
        isHandlingPinVerification = true
        coordinator.setVerifying(true)

        Task {
            defer {
                isHandlingPinVerification = false
                coordinator.setVerifying(false)
            }

            guard let identityServiceClient else {
                coordinator.displayError(L10n.errorUnknown)
                return
            }

            do {
                let session = try await identityServiceClient.verifyPinChallenge(pinChallengeToken: context.challengeToken,
                                                                                 pin: pin,
                                                                                 device: .current)
                await signIn(with: session, fromCoordinatorError: coordinator.displayError)
            } catch IdentityServiceError.pinChallengeExpired {
                if stateMachine.state == .pinChallengeScreen {
                    stateMachine.tryEvent(.cancelledPinChallenge)
                }
            } catch {
                MXLog.error("Failed verifying PIN challenge: \(error)")
                coordinator.displayError((error as? LocalizedError)?.errorDescription ?? L10n.errorUnknown)
            }
        }
    }

    private func showStartScreen(fromState: State, applying provisioningParameters: AccountProvisioningParameters? = nil) {
        let mediaProvider = authenticationService.classicAppAccount.map { account in
            MediaProvider(mediaLoader: ClassicAppMediaLoader(classicAppAccount: account),
                          imageCache: .onlyInMemory,
                          homeserverReachabilityPublisher: appMediator.networkMonitor.reachabilityPublisher) // Close enough approximation
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
                    stateMachine.tryEvent(.confirmServer(.login))
                case .register:
                    stateMachine.tryEvent(.confirmServer(.register))
                    
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
                stateMachine.tryEvent(.confirmServer(.login))
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
            case .continueWithOAuth(let oAuthData, let window):
                showOAuthAuthentication(oAuthData: oAuthData, presentationAnchor: window)
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
    
    /// **Note:** We have intentionally excluded this presentation from the state machine as it doesn't mutate our navigation stack and there
    /// isn't a robust way to detect why the user returned to the app when the MAS URL directly opens an external app for authentication without
    /// presenting a web authentication session.
    private func showOAuthAuthentication(oAuthData: OAuthAuthorizationDataProxy, presentationAnchor: UIWindow) {
        let presenter = OAuthAuthenticationPresenter(authenticationService: authenticationService,
                                                     redirectURL: appSettings.oAuthRedirectURL,
                                                     presentationAnchor: presentationAnchor,
                                                     appMediator: appMediator,
                                                     appHooks: appHooks,
                                                     userIndicatorController: userIndicatorController)
        oAuthPresenter = presenter
        
        Task {
            switch await presenter.authenticate(using: oAuthData) {
            case .success(let userSession):
                stateMachine.tryEvent(.signedIn, userInfo: userSession)
            case .failure:
                break // Nothing to do, any alerts will be handled by the presenter.
            }
            oAuthPresenter = nil
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
                                                            appHooks: appHooks,
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
    }
}
