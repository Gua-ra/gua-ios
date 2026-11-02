//
// Copyright Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import MatrixRustSDK
import XCTest

@MainActor
final class AuthenticationFlowCoordinatorSignInFailureTests: XCTestCase {
    private static let shortStepTimeout: Duration = .milliseconds(300)

    private var authenticationService: AuthenticationServiceFake!
    private var flowCoordinator: AuthenticationFlowCoordinator!

    override func setUp() {
        XCTAssertFalse(ServiceLocator.shared.settings.legacyAuthEnabled)
        authenticationService = AuthenticationServiceFake()
    }

    override func tearDown() {
        authenticationService.answerAll()
    }

    func testAnUnreachableResolverShowsAConnectionError() async throws {
        let phoneEntry = try startFlow(resolver: ResolverClientStub(isReachable: false))

        let state = try await submit(.continueTapped, on: phoneEntry)

        XCTAssertEqual(state.errorMessage, UntranslatedL10n.guaSignInConnectionFailed)
        XCTAssertEqual(authenticationService.configureCallsCount, 0)
    }

    func testAConfigureThatNeverAnswersShowsAConnectionError() async throws {
        let phoneEntry = try startFlow(stepTimeout: Self.shortStepTimeout)

        let state = try await submit(.continueTapped, on: phoneEntry)

        XCTAssertEqual(state.errorMessage, UntranslatedL10n.guaSignInConnectionFailed)
        XCTAssertFalse(state.isSubmitting)
        XCTAssertEqual(authenticationService.configureCallsCount, 1)
    }

    func testAFailedConfigureShowsTranslatedCopy() async throws {
        authenticationService.configureResult = .failure(.invalidServer)
        let phoneEntry = try startFlow()

        let state = try await submit(.continueTapped, on: phoneEntry)

        XCTAssertEqual(state.errorMessage, L10n.errorUnknown)
        XCTAssertFalse(state.isSubmitting)
    }

    func testAnAuthorizationURLThatNeverArrivesShowsAConnectionError() async throws {
        authenticationService.configureResult = .success(())
        let phoneEntry = try startFlow(stepTimeout: Self.shortStepTimeout)

        let state = try await submit(.continueTapped, on: phoneEntry)

        XCTAssertEqual(state.errorMessage, UntranslatedL10n.guaSignInConnectionFailed)
        XCTAssertFalse(state.isSubmitting)
        XCTAssertEqual(authenticationService.urlForOIDCLoginCallsCount, 1)
    }

    func testPasskeySignInShowsTranslatedCopyWhenConfigureFails() async throws {
        authenticationService.configureResult = .failure(.invalidServer)
        let phoneEntry = try startFlow()

        let state = try await submit(.signInWithPasskeyTapped, on: phoneEntry)

        XCTAssertEqual(state.errorMessage, L10n.errorUnknown)
    }

    func testPasskeySignInShowsAConnectionErrorWhenTheAuthorizationURLFails() async throws {
        authenticationService.configureResult = .success(())
        authenticationService.urlForOIDCLoginResult = .failure(.oidcError(.urlFailure))
        let phoneEntry = try startFlow()

        let state = try await submit(.signInWithPasskeyTapped, on: phoneEntry)

        XCTAssertEqual(state.errorMessage, UntranslatedL10n.guaSignInConnectionFailed)
    }

    func testANewContinueConfiguresOnlyAfterTheAbandonedConfigureReturns() async throws {
        let phoneEntry = try startFlow(stepTimeout: Self.shortStepTimeout)
        try await submit(.continueTapped, on: phoneEntry)

        let state = try await submit(.continueTapped, on: phoneEntry)

        XCTAssertEqual(state.errorMessage, UntranslatedL10n.guaSignInConnectionFailed)
        XCTAssertEqual(authenticationService.configureCallsCount, 1)

        let secondConfigure = deferFulfillment(authenticationService.configureCalls) { $0 == 2 }
        authenticationService.answerFirstConfigure(with: .success(()))
        try await secondConfigure.fulfill()
    }

    // MARK: - Helpers

    private func startFlow(resolver: ResolverClientStub = ResolverClientStub(),
                           stepTimeout: Duration = GuaSignInError.stepTimeout) throws -> PhoneEntryScreenCoordinator {
        let windowManager = WindowManagerMock()
        windowManager.mainWindow = UIWindow()
        let appMediator = AppMediatorMock.default
        appMediator.underlyingWindowManager = windowManager
        let navigationRootCoordinator = NavigationRootCoordinator()

        flowCoordinator = AuthenticationFlowCoordinator(authenticationService: authenticationService,
                                                        bugReportService: BugReportServiceMock(.init()),
                                                        navigationRootCoordinator: navigationRootCoordinator,
                                                        appMediator: appMediator,
                                                        appSettings: ServiceLocator.shared.settings,
                                                        analytics: ServiceLocator.shared.analytics,
                                                        userIndicatorController: UserIndicatorControllerMock(),
                                                        resolverClient: resolver,
                                                        usesPhoneLoginHint: true,
                                                        signInStepTimeout: stepTimeout)
        flowCoordinator.start()

        let navigationStackCoordinator = try XCTUnwrap(navigationRootCoordinator.rootCoordinator as? NavigationStackCoordinator)
        let phoneEntry = try XCTUnwrap(navigationStackCoordinator.rootCoordinator as? PhoneEntryScreenCoordinator)
        phoneEntry.viewModel.context.localPhoneNumber = "5551234567"
        return phoneEntry
    }

    /// Sends `action` and returns the screen state once the attempt it starts has ended.
    @discardableResult
    private func submit(_ action: PhoneEntryScreenViewAction, on phoneEntry: PhoneEntryScreenCoordinator) async throws -> PhoneEntryScreenViewState {
        let context = phoneEntry.viewModel.context
        let attemptEnded = deferFulfillment(context.observe(\.viewState.isSubmitting), transitionValues: [true, false])
        context.send(viewAction: action)
        try await attemptEnded.fulfill()
        return context.viewState
    }
}

private struct ResolverClientStub: ResolverClientProtocol {
    var isReachable = true

    func resolve(phoneNumber: String) async throws -> HomeserverResolution {
        guard isReachable else { throw ResolverError.transport(URLError(.notConnectedToInternet)) }
        return HomeserverResolution(exists: true,
                                    homeserver: ResolvedHomeserver(serverName: "example.com", baseURL: "https://example.com", masIssuer: nil, region: nil))
    }
}

/// Answers `configure` with `configureResult`, or holds each call until the test answers it.
/// Answers `urlForOIDCLogin` with `urlForOIDCLoginResult`, or never.
@MainActor
private final class AuthenticationServiceFake: AuthenticationServiceProtocol {
    var configureResult: Result<Void, AuthenticationServiceError>?
    var urlForOIDCLoginResult: Result<OIDCAuthorizationDataProxy, AuthenticationServiceError>?

    let configureCalls = PassthroughSubject<Int, Never>()
    private(set) var configureCallsCount = 0
    private(set) var urlForOIDCLoginCallsCount = 0

    private var heldConfigures: [CheckedContinuation<Result<Void, AuthenticationServiceError>, Never>] = []
    private var heldURLRequests: [CheckedContinuation<Result<OIDCAuthorizationDataProxy, AuthenticationServiceError>, Never>] = []

    nonisolated var homeserver: CurrentValuePublisher<LoginHomeserver, Never> {
        .init(.mockOIDC)
    }

    nonisolated var flow: AuthenticationFlow {
        .login
    }

    nonisolated var qrLoginProgressPublisher: AnyPublisher<QrLoginProgress, Never> {
        Empty().eraseToAnyPublisher()
    }

    func answerFirstConfigure(with result: Result<Void, AuthenticationServiceError>) {
        heldConfigures.removeFirst().resume(returning: result)
    }

    func answerAll() {
        heldConfigures.forEach { $0.resume(returning: .failure(.invalidServer)) }
        heldConfigures = []
        heldURLRequests.forEach { $0.resume(returning: .failure(.oidcError(.unknown))) }
        heldURLRequests = []
    }

    nonisolated func configure(for homeserverAddress: String, flow: AuthenticationFlow) async -> Result<Void, AuthenticationServiceError> {
        await nextConfigureResult()
    }

    nonisolated func urlForOIDCLogin(loginHint: String?) async -> Result<OIDCAuthorizationDataProxy, AuthenticationServiceError> {
        await nextURLResult()
    }

    nonisolated func abortOIDCLogin(data: OIDCAuthorizationDataProxy) async { }

    nonisolated func loginWithOIDCCallback(_ callbackURL: URL) async -> Result<UserSessionProtocol, AuthenticationServiceError> {
        .failure(.failedLoggingIn)
    }

    nonisolated func login(username: String, password: String, initialDeviceName: String?, deviceID: String?) async -> Result<UserSessionProtocol, AuthenticationServiceError> {
        .failure(.failedLoggingIn)
    }

    nonisolated func loginWithExistingMatrixSession(accessToken: String,
                                                    refreshToken: String?,
                                                    userId: String,
                                                    deviceId: String,
                                                    homeserverUrl: String) async -> Result<UserSessionProtocol, AuthenticationServiceError> {
        .failure(.failedLoggingIn)
    }

    nonisolated func loginWithQRCode(data: Data) async -> Result<UserSessionProtocol, AuthenticationServiceError> {
        .failure(.failedLoggingIn)
    }

    nonisolated func reset() { }

    private func nextConfigureResult() async -> Result<Void, AuthenticationServiceError> {
        configureCallsCount += 1
        configureCalls.send(configureCallsCount)
        if let configureResult {
            return configureResult
        }
        return await withCheckedContinuation { heldConfigures.append($0) }
    }

    private func nextURLResult() async -> Result<OIDCAuthorizationDataProxy, AuthenticationServiceError> {
        urlForOIDCLoginCallsCount += 1
        if let urlForOIDCLoginResult {
            return urlForOIDCLoginResult
        }
        return await withCheckedContinuation { heldURLRequests.append($0) }
    }
}
