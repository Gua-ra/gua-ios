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
}
