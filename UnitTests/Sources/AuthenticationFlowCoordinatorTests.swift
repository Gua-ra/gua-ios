//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import XCTest

@MainActor
final class AuthenticationFlowCoordinatorTests: XCTestCase {
    private var navigationRootCoordinator: NavigationRootCoordinator!
    private var resolverClient: ResolverClientFake!
    private var oidcPresenter: OIDCAuthenticationPresenterFake!
    private var flowCoordinator: AuthenticationFlowCoordinator!

    override func setUp() {
        XCTAssertTrue(ServiceLocator.shared.settings.allowOtherAccountProviders)
        XCTAssertFalse(ServiceLocator.shared.settings.legacyAuthEnabled)

        let windowManager = WindowManagerMock()
        windowManager.mainWindow = UIWindow()
        let appMediator = AppMediatorMock.default
        appMediator.underlyingWindowManager = windowManager

        navigationRootCoordinator = NavigationRootCoordinator()
        resolverClient = ResolverClientFake()
        let oidcPresenter = OIDCAuthenticationPresenterFake()
        self.oidcPresenter = oidcPresenter
        flowCoordinator = AuthenticationFlowCoordinator(authenticationService: AuthenticationService.mock,
                                                        bugReportService: BugReportServiceMock(.init()),
                                                        navigationRootCoordinator: navigationRootCoordinator,
                                                        appMediator: appMediator,
                                                        appSettings: ServiceLocator.shared.settings,
                                                        analytics: ServiceLocator.shared.analytics,
                                                        userIndicatorController: UserIndicatorControllerMock(),
                                                        resolverClient: resolverClient,
                                                        usesPhoneLoginHint: true) { _ in oidcPresenter }
    }

    override func tearDown() {
        oidcPresenter.finish(with: .failure(.oidcError(.userCancellation)))
    }

    func testRepeatedOIDCRequestDuringOIDCAuthenticationIsIgnored() {
        XCTAssertTrue(AuthenticationFlowCoordinator.ignoresUnroutedEvent(.continueWithOIDC, from: .oidcAuthentication))
    }

    func testEventsAfterCompletionAreIgnored() {
        XCTAssertTrue(AuthenticationFlowCoordinator.ignoresUnroutedEvent(.signedIn, from: .complete))
        XCTAssertTrue(AuthenticationFlowCoordinator.ignoresUnroutedEvent(.continueWithOIDC, from: .complete))
    }

    func testOtherUnroutedEventsAreNotIgnored() {
        XCTAssertFalse(AuthenticationFlowCoordinator.ignoresUnroutedEvent(.continueWithOIDC, from: .loginScreen))
        XCTAssertFalse(AuthenticationFlowCoordinator.ignoresUnroutedEvent(.continueWithOIDC, from: .bugReportFlow))
        XCTAssertFalse(AuthenticationFlowCoordinator.ignoresUnroutedEvent(.continueWithPassword, from: .oidcAuthentication))
        XCTAssertFalse(AuthenticationFlowCoordinator.ignoresUnroutedEvent(.startPhoneAuth, from: .oidcAuthentication))
        XCTAssertFalse(AuthenticationFlowCoordinator.ignoresUnroutedEvent(nil, from: .oidcAuthentication))
    }

    func testProvisioningLinkOnThePhoneEntryScreenIsIgnored() throws {
        flowCoordinator.start()

        flowCoordinator.handleAppRoute(.accountProvisioningLink(.init(accountProvider: "example.com", loginHint: nil)), animated: false)

        XCTAssertNotNil(try phoneEntryScreenCoordinator())
    }

    func testPhoneEntryScreenStaysDisabledWhileSignInIsOpen() async throws {
        let phoneEntry = try await continueToSignIn()

        XCTAssertTrue(phoneEntry.viewModel.context.viewState.isSubmitting)
        XCTAssertEqual(resolverClient.resolveCallsCount, 1)
        XCTAssertEqual(oidcPresenter.authenticateCallsCount, 1)
    }

    func testContinueReachingTheCoordinatorWhileSignInIsOpenIsIgnored() async throws {
        let phoneEntry = try await continueToSignIn()

        phoneEntry.setSubmitting(false)
        let repeatedResolve = deferFailure(resolverClient.resolveCalls, timeout: 1) { _ in true }
        phoneEntry.viewModel.context.send(viewAction: .continueTapped)
        try await repeatedResolve.fulfill()

        XCTAssertEqual(resolverClient.resolveCallsCount, 1)
        XCTAssertEqual(oidcPresenter.authenticateCallsCount, 1)
    }

    func testCancellingSignInEnablesThePhoneEntryScreen() async throws {
        let phoneEntry = try await continueToSignIn()
        let context = phoneEntry.viewModel.context

        let enabled = deferFulfillment(context.observe(\.viewState.isSubmitting)) { !$0 }
        oidcPresenter.finish(with: .failure(.oidcError(.userCancellation)))
        try await enabled.fulfill()
        XCTAssertTrue(context.viewState.canContinue)

        let signInStarted = deferFulfillment(oidcPresenter.authenticationStarted) { _ in true }
        context.send(viewAction: .continueTapped)
        try await signInStarted.fulfill()
        XCTAssertEqual(resolverClient.resolveCallsCount, 2)
    }

    func testProvisioningLinkWhileSignInIsOpenLeavesSignInRunning() async throws {
        let phoneEntry = try await continueToSignIn()
        let context = phoneEntry.viewModel.context

        flowCoordinator.handleAppRoute(.accountProvisioningLink(.init(accountProvider: "example.com", loginHint: nil)), animated: false)

        XCTAssertEqual(oidcPresenter.cancelCallsCount, 0)
        XCTAssertTrue(context.viewState.isSubmitting)

        let enabled = deferFulfillment(context.observe(\.viewState.isSubmitting)) { !$0 }
        oidcPresenter.finish(with: .failure(.oidcError(.userCancellation)))
        try await enabled.fulfill()
        XCTAssertTrue(try phoneEntryScreenCoordinator() === phoneEntry)
    }

    // MARK: - Helpers

    private func phoneEntryScreenCoordinator() throws -> PhoneEntryScreenCoordinator {
        let navigationStackCoordinator = try XCTUnwrap(navigationRootCoordinator.rootCoordinator as? NavigationStackCoordinator)
        return try XCTUnwrap(navigationStackCoordinator.rootCoordinator as? PhoneEntryScreenCoordinator)
    }

    private func continueToSignIn() async throws -> PhoneEntryScreenCoordinator {
        flowCoordinator.start()
        let phoneEntry = try phoneEntryScreenCoordinator()
        let context = phoneEntry.viewModel.context
        context.localPhoneNumber = "5551234567"

        let signInStarted = deferFulfillment(oidcPresenter.authenticationStarted) { _ in true }
        context.send(viewAction: .continueTapped)
        try await signInStarted.fulfill()
        return phoneEntry
    }
}

@MainActor
private final class ResolverClientFake: ResolverClientProtocol {
    let resolveCalls = PassthroughSubject<String, Never>()
    private(set) var resolveCallsCount = 0

    nonisolated func resolve(phoneNumber: String) async throws -> HomeserverResolution {
        await recordResolve(phoneNumber)
        return HomeserverResolution(exists: true,
                                    homeserver: ResolvedHomeserver(serverName: "matrix.org", baseURL: "matrix.org", masIssuer: nil, region: nil))
    }

    private func recordResolve(_ phoneNumber: String) {
        resolveCallsCount += 1
        resolveCalls.send(phoneNumber)
    }
}

@MainActor
private final class OIDCAuthenticationPresenterFake: OIDCAuthenticationPresenterProtocol {
    let authenticationStarted = PassthroughSubject<Void, Never>()
    private(set) var authenticateCallsCount = 0
    private(set) var cancelCallsCount = 0

    private var pendingAuthentication: CheckedContinuation<Void, Never>?
    private var result: Result<UserSessionProtocol, AuthenticationServiceError> = .failure(.oidcError(.userCancellation))

    func authenticate(using oidcData: OIDCAuthorizationDataProxy) async -> Result<UserSessionProtocol, AuthenticationServiceError> {
        authenticateCallsCount += 1
        await withCheckedContinuation { continuation in
            pendingAuthentication = continuation
            authenticationStarted.send(())
        }
        return result
    }

    func cancel() {
        cancelCallsCount += 1
    }

    func finish(with result: Result<UserSessionProtocol, AuthenticationServiceError>) {
        self.result = result
        pendingAuthentication?.resume()
        pendingAuthentication = nil
    }
}
