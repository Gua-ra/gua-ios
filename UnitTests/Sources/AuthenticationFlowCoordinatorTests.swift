//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import XCTest

@MainActor
final class AuthenticationFlowCoordinatorTests: XCTestCase {
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
        XCTAssertTrue(ServiceLocator.shared.settings.allowOtherAccountProviders)
        XCTAssertFalse(ServiceLocator.shared.settings.legacyAuthEnabled)
        let navigationRootCoordinator = NavigationRootCoordinator()
        let coordinator = AuthenticationFlowCoordinator(authenticationService: AuthenticationService.mock,
                                                        bugReportService: BugReportServiceMock(.init()),
                                                        navigationRootCoordinator: navigationRootCoordinator,
                                                        appMediator: AppMediatorMock.default,
                                                        appSettings: ServiceLocator.shared.settings,
                                                        analytics: ServiceLocator.shared.analytics,
                                                        userIndicatorController: UserIndicatorControllerMock(),
                                                        usesPhoneLoginHint: true)
        coordinator.start()

        coordinator.handleAppRoute(.accountProvisioningLink(.init(accountProvider: "example.com", loginHint: nil)), animated: false)

        let navigationStackCoordinator = try XCTUnwrap(navigationRootCoordinator.rootCoordinator as? NavigationStackCoordinator)
        XCTAssertTrue(navigationStackCoordinator.rootCoordinator is PhoneEntryScreenCoordinator)
    }
}
