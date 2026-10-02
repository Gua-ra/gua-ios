//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import XCTest

/// The query parameters Gua appends to MAS URLs. They are added to the raw percent-encoded query, so
/// whatever the SDK already escaped has to come out byte for byte.
final class AccountManagementURLTests: XCTestCase {
    func testLoginHintNamesTheSignedInAccount() throws {
        var components = try XCTUnwrap(URLComponents(string: "https://auth.example/account/?action=org.matrix.profile"))

        components.appendAccountLoginHintPreservingEncoding(userID: "@alice:example.org")

        XCTAssertEqual(components.percentEncodedQuery,
                       "action=org.matrix.profile&org.matrix.msc4198.login_hint=mxid:@alice:example.org")
        XCTAssertEqual(components.queryItems?.last, URLQueryItem(name: "org.matrix.msc4198.login_hint", value: "mxid:@alice:example.org"))
    }

    func testLoginHintLeavesExistingEscapesAlone() throws {
        var components = try XCTUnwrap(URLComponents(string: "https://auth.example/account/?login_hint=%2B15551234567&ui_locales=fr"))

        components.appendAccountLoginHintPreservingEncoding(userID: "@bob:example.org")

        let query = try XCTUnwrap(components.percentEncodedQuery)
        XCTAssertTrue(query.hasPrefix("login_hint=%2B15551234567&ui_locales=fr&"))
        XCTAssertEqual(components.queryItems?.first?.value, "+15551234567")
    }

    func testLoginHintEscapesCharactersThatWouldBeMisread() throws {
        var components = try XCTUnwrap(URLComponents(string: "https://auth.example/account/"))

        components.appendAccountLoginHintPreservingEncoding(userID: "@a+b=c&d:example.org")

        XCTAssertEqual(components.percentEncodedQuery,
                       "org.matrix.msc4198.login_hint=mxid:@a%2Bb%3Dc%26d:example.org")
        XCTAssertEqual(components.queryItems?.first?.value, "mxid:@a+b=c&d:example.org")
    }

    func testUILocalesStillAppendsAfterTheExistingQuery() throws {
        var components = try XCTUnwrap(URLComponents(string: "https://auth.example/authorize?login_hint=%2B15551234567"))

        components.appendUILocalesPreservingEncoding(languageCode: "pt")

        XCTAssertEqual(components.percentEncodedQuery, "login_hint=%2B15551234567&ui_locales=pt")
    }
}
