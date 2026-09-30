//
// Copyright Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import XCTest

/// The notification extension stands down on a fresh marker and only on a fresh marker.
class IdentityResetMarkerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAFreshMarkerStandsTheExtensionDown() {
        XCTAssertTrue(IdentityResetMarker.isFresh(startedAt: now.addingTimeInterval(-5), now: now))
        XCTAssertTrue(IdentityResetMarker.isFresh(startedAt: now.addingTimeInterval(-(IdentityResetMarker.maxAge - 1)), now: now))
    }

    func testAnExpiredMarkerDoesNot() {
        XCTAssertFalse(IdentityResetMarker.isFresh(startedAt: now.addingTimeInterval(-IdentityResetMarker.maxAge), now: now))
        XCTAssertFalse(IdentityResetMarker.isFresh(startedAt: now.addingTimeInterval(-3600), now: now))
    }

    func testAnAbsentMarkerDoesNot() {
        XCTAssertFalse(IdentityResetMarker.isFresh(startedAt: nil, now: now))
    }

    /// A clock adjustment may date a marker slightly ahead; far ahead it is not trusted.
    func testAFutureMarkerIsTrustedOnlyWithinTolerance() {
        XCTAssertTrue(IdentityResetMarker.isFresh(startedAt: now.addingTimeInterval(IdentityResetMarker.futureTolerance - 1), now: now))
        XCTAssertFalse(IdentityResetMarker.isFresh(startedAt: now.addingTimeInterval(IdentityResetMarker.futureTolerance + 1), now: now))
    }

    /// Storage is per account; another account's marker is not this one's.
    func testTheMarkerIsAccountSpecific() {
        AppSettings.resetAllSettings()
        let settings = AppSettings()
        settings.setIdentityResetStartedAt(now, forUserID: "@one:example.org")

        XCTAssertEqual(settings.identityResetStartedAt(forUserID: "@one:example.org"), now)
        XCTAssertNil(settings.identityResetStartedAt(forUserID: "@two:example.org"))

        settings.setIdentityResetStartedAt(nil, forUserID: "@one:example.org")
        XCTAssertNil(settings.identityResetStartedAt(forUserID: "@one:example.org"))
        AppSettings.resetAllSettings()
    }
}
