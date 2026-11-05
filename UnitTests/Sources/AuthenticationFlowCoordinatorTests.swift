//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import Foundation
import Testing
import UIKit

@MainActor
final class AuthenticationFlowCoordinatorTests {
    private var navigationRootCoordinator: NavigationRootCoordinator!
    private var resolverClient: ResolverClientFake!
    private var oAuthPresenter: OAuthAuthenticationPresenterFake!
    private var flowCoordinator: AuthenticationFlowCoordinator!
    
    init() {
        let appSettings = AppSettings.volatile()
        #expect(appSettings.allowOtherAccountProviders)
        #expect(!appSettings.legacyAuthEnabled)
        
        let appMediator = AppMediatorMock(.init())
        (appMediator.windowManager as? WindowManagerMock)?.mainWindow = UIWindow()
        
        navigationRootCoordinator = NavigationRootCoordinator()
        resolverClient = ResolverClientFake()
        let oAuthPresenter = OAuthAuthenticationPresenterFake()
        self.oAuthPresenter = oAuthPresenter
        flowCoordinator = AuthenticationFlowCoordinator(authenticationService: AuthenticationService.mock,
                                                        bugReportService: BugReportServiceMock(.init()),
                                                        navigationRootCoordinator: navigationRootCoordinator,
                                                        appMediator: appMediator,
                                                        appSettings: appSettings,
                                                        appHooks: AppHooks(),
                                                        userIndicatorController: UserIndicatorControllerMock(),
                                                        resolverClient: resolverClient,
                                                        usesPhoneLoginHint: true) { _ in oAuthPresenter }
    }
    
    isolated deinit {
        oAuthPresenter.finish(with: .failure(.oAuthError(.userCancellation)))
    }
    
    @Test
    func eventsAfterCompletionAreIgnored() {
        #expect(AuthenticationFlowCoordinator.ignoresUnroutedEvent(.signedIn, from: .complete))
        #expect(AuthenticationFlowCoordinator.ignoresUnroutedEvent(.startPhoneAuth, from: .complete))
    }
    
    @Test
    func otherUnroutedEventsAreNotIgnored() {
        #expect(!AuthenticationFlowCoordinator.ignoresUnroutedEvent(.continueWithPassword, from: .phoneEntryScreen))
        #expect(!AuthenticationFlowCoordinator.ignoresUnroutedEvent(.startPhoneAuth, from: .loginScreen))
        #expect(!AuthenticationFlowCoordinator.ignoresUnroutedEvent(nil, from: .bugReportFlow))
    }
    
    @Test
    func provisioningLinkOnThePhoneEntryScreenIsIgnored() throws {
        flowCoordinator.start()
        
        flowCoordinator.handleAppRoute(.accountProvisioningLink(.init(accountProvider: "example.com", loginHint: nil)), animated: false)
        
        #expect(try (phoneEntryScreenCoordinator()) != nil)
    }
    
    @Test
    func phoneEntryScreenStaysDisabledWhileSignInIsOpen() async throws {
        let phoneEntry = try await continueToSignIn()
        
        #expect(phoneEntry.viewModel.context.viewState.isSubmitting)
        #expect(resolverClient.resolveCallsCount == 1)
        #expect(oAuthPresenter.authenticateCallsCount == 1)
    }
    
    @Test
    func continueReachingTheCoordinatorWhileSignInIsOpenIsIgnored() async throws {
        let phoneEntry = try await continueToSignIn()
        
        phoneEntry.setSubmitting(false)
        let repeatedResolve = deferFailure(resolverClient.resolveCalls, timeout: .seconds(1)) { _ in true }
        phoneEntry.viewModel.context.send(viewAction: .continueTapped)
        try await repeatedResolve.fulfill()
        
        #expect(resolverClient.resolveCallsCount == 1)
        #expect(oAuthPresenter.authenticateCallsCount == 1)
    }
    
    @Test
    func cancellingSignInEnablesThePhoneEntryScreen() async throws {
        let phoneEntry = try await continueToSignIn()
        let context = phoneEntry.viewModel.context
        
        let enabled = deferFulfillment(context.observe(\.viewState.isSubmitting)) { !$0 }
        oAuthPresenter.finish(with: .failure(.oAuthError(.userCancellation)))
        try await enabled.fulfill()
        #expect(context.viewState.canContinue)
        
        let signInStarted = deferFulfillment(oAuthPresenter.authenticationStarted) { _ in true }
        context.send(viewAction: .continueTapped)
        try await signInStarted.fulfill()
        #expect(resolverClient.resolveCallsCount == 2)
    }
    
    @Test
    func provisioningLinkWhileSignInIsOpenLeavesSignInRunning() async throws {
        let phoneEntry = try await continueToSignIn()
        let context = phoneEntry.viewModel.context
        
        flowCoordinator.handleAppRoute(.accountProvisioningLink(.init(accountProvider: "example.com", loginHint: nil)), animated: false)
        
        #expect(oAuthPresenter.cancelCallsCount == 0)
        #expect(context.viewState.isSubmitting)
        
        let enabled = deferFulfillment(context.observe(\.viewState.isSubmitting)) { !$0 }
        oAuthPresenter.finish(with: .failure(.oAuthError(.userCancellation)))
        try await enabled.fulfill()
        #expect(try phoneEntryScreenCoordinator() === phoneEntry)
    }
    
    // MARK: - Helpers
    
    private func phoneEntryScreenCoordinator() throws -> PhoneEntryScreenCoordinator {
        let navigationStackCoordinator = try #require(navigationRootCoordinator.rootCoordinator as? NavigationStackCoordinator)
        return try #require(navigationStackCoordinator.rootCoordinator as? PhoneEntryScreenCoordinator)
    }
    
    private func continueToSignIn() async throws -> PhoneEntryScreenCoordinator {
        flowCoordinator.start()
        let phoneEntry = try phoneEntryScreenCoordinator()
        let context = phoneEntry.viewModel.context
        context.localPhoneNumber = "5551234567"
        
        let signInStarted = deferFulfillment(oAuthPresenter.authenticationStarted) { _ in true }
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
private final class OAuthAuthenticationPresenterFake: OAuthAuthenticationPresenterProtocol {
    let authenticationStarted = PassthroughSubject<Void, Never>()
    private(set) var authenticateCallsCount = 0
    private(set) var cancelCallsCount = 0
    
    private var pendingAuthentication: CheckedContinuation<Void, Never>?
    private var result: Result<UserSessionProtocol, AuthenticationServiceError> = .failure(.oAuthError(.userCancellation))
    
    func authenticate(using oAuthData: OAuthAuthorizationDataProxy) async -> Result<UserSessionProtocol, AuthenticationServiceError> {
        authenticateCallsCount += 1
        await withCheckedContinuation { continuation in
            pendingAuthentication = continuation
            authenticationStarted.send(())
        }
        return result
    }
    
    func handleUniversalLinkCallback(_ url: URL) { }
    
    func cancel() {
        cancelCallsCount += 1
    }
    
    func finish(with result: Result<UserSessionProtocol, AuthenticationServiceError>) {
        self.result = result
        pendingAuthentication?.resume()
        pendingAuthentication = nil
    }
}
