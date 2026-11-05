//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

/// The query parameters Gua appends to MAS URLs. They are added to the raw percent-encoded query, so
/// whatever the SDK already escaped has to come out byte for byte.
final class AccountManagementURLTests {
    @Test
    func loginHintNamesTheSignedInAccount() throws {
        var components = try #require(URLComponents(string: "https://auth.example/account/?action=org.matrix.profile"))
        
        components.appendAccountLoginHintPreservingEncoding(userID: "@alice:example.org")
        
        #expect(components.percentEncodedQuery == "action=org.matrix.profile&org.matrix.msc4198.login_hint=mxid:@alice:example.org")
        #expect(components.queryItems?.last == URLQueryItem(name: "org.matrix.msc4198.login_hint", value: "mxid:@alice:example.org"))
    }
    
    @Test
    func loginHintLeavesExistingEscapesAlone() throws {
        var components = try #require(URLComponents(string: "https://auth.example/account/?login_hint=%2B15551234567&ui_locales=fr"))
        
        components.appendAccountLoginHintPreservingEncoding(userID: "@bob:example.org")
        
        let query = try #require(components.percentEncodedQuery)
        #expect(query.hasPrefix("login_hint=%2B15551234567&ui_locales=fr&"))
        #expect(components.queryItems?.first?.value == "+15551234567")
    }
    
    @Test
    func loginHintEscapesCharactersThatWouldBeMisread() throws {
        var components = try #require(URLComponents(string: "https://auth.example/account/"))
        
        components.appendAccountLoginHintPreservingEncoding(userID: "@a+b=c&d:example.org")
        
        #expect(components.percentEncodedQuery == "org.matrix.msc4198.login_hint=mxid:@a%2Bb%3Dc%26d:example.org")
        #expect(components.queryItems?.first?.value == "mxid:@a+b=c&d:example.org")
    }
    
    @Test
    func uiLocalesStillAppendsAfterTheExistingQuery() throws {
        var components = try #require(URLComponents(string: "https://auth.example/authorize?login_hint=%2B15551234567"))
        
        components.appendUILocalesPreservingEncoding(languageCode: "pt")
        
        #expect(components.percentEncodedQuery == "login_hint=%2B15551234567&ui_locales=pt")
    }
    
    @Test
    func uiLocalesDefaultsToTheAppLanguage() throws {
        defer { Bundle.overrideLocalizations = nil }
        Bundle.overrideLocalizations = ["pt-BR"]
        var components = try #require(URLComponents(string: "https://auth.example/authorize?login_hint=%2B15551234567"))
        
        components.appendUILocalesPreservingEncoding()
        
        #expect(components.percentEncodedQuery == "login_hint=%2B15551234567&ui_locales=pt-BR")
    }
}
