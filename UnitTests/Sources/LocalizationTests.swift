//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import XCTest

class LocalizationTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        Bundle.overrideLocalizations = nil
    }

    /// Test ElementL10n considers app language changes
    func testAppLanguage() {
        // set app language to English
        Bundle.overrideLocalizations = ["en"]

        XCTAssertEqual(L10n.testLanguageIdentifier, "en")

        // set app language to Italian
        Bundle.overrideLocalizations = ["it"]

        XCTAssertEqual(L10n.testLanguageIdentifier, "it")
    }

    /// Test fallback language for a language not supported at all
    func testFallbackOnNotSupportedLanguage() {
        //  set app language to something Element don't support at all (chose non existing identifier)
        Bundle.overrideLocalizations = ["xx"]

        XCTAssertEqual(L10n.testLanguageIdentifier, "en")
    }

    /// Test fallback language for a language supported but poorly translated
    func testFallbackOnNotTranslatedKey() {
        //  set app language to something Element supports but use a key that is not translated (we have a key that should never be translated)
        Bundle.overrideLocalizations = ["it"]

        XCTAssertEqual(L10n.testLanguageIdentifier, "it")
        XCTAssertEqual(L10n.testUntranslatedDefaultLanguageIdentifier, "en")
    }

    /// Test plurals that ElementL10n considers app language changes
    func testPlurals() {
        //  set app language to English
        Bundle.overrideLocalizations = ["en"]

        XCTAssertEqual(L10n.commonMemberCount(1), "1 Member")
        XCTAssertEqual(L10n.commonMemberCount(2), "2 Members")

        //  set app language to Italian
        Bundle.overrideLocalizations = ["it"]

        XCTAssertEqual(L10n.commonMemberCount(1), "1 Membro")
        XCTAssertEqual(L10n.commonMemberCount(2), "2 Membri")
    }

    /// Test plurals fallback language for a language not supported at all
    func testPluralsFallbackOnNotSupportedLanguage() {
        //  set app language to something Element don't support at all ("invalid identifier")
        Bundle.overrideLocalizations = ["xx"]

        XCTAssertEqual(L10n.commonMemberCount(1), "1 Member")
        XCTAssertEqual(L10n.commonMemberCount(2), "2 Members")
    }

    /// Test untranslated strings
    func testUntranslated() {
        XCTAssertEqual(UntranslatedL10n.untranslated, "Untranslated")
        XCTAssertEqual(UntranslatedL10n.untranslatedPlural(1), "One untranslated item")
        XCTAssertEqual(UntranslatedL10n.untranslatedPlural(5), "5 untranslated items")
    }

    /// Gua keeps its own translations in the Untranslated table, so it must follow the app language like L10n.
    func testUntranslatedFollowsAppLanguage() throws {
        let english = try XCTUnwrap(untranslatedValue("gua_sign_in_with_passkey", language: "en"))

        for language in ["pt-BR", "es", "fr"] {
            Bundle.overrideLocalizations = [language]

            let expected = try XCTUnwrap(untranslatedValue("gua_sign_in_with_passkey", language: language))
            XCTAssertNotEqual(expected, english, "\(language) has no translation for gua_sign_in_with_passkey")
            XCTAssertEqual(UntranslatedL10n.guaSignInWithPasskey, expected)
        }

        Bundle.overrideLocalizations = ["xx"]
        XCTAssertEqual(UntranslatedL10n.guaSignInWithPasskey, english)
    }

    /// A key the app language lacks falls back to English instead of showing the key.
    func testUntranslatedFallsBackForMissingKey() {
        Bundle.overrideLocalizations = ["pt-BR"]

        XCTAssertNil(untranslatedValue("untranslated", language: "pt-BR"))
        XCTAssertEqual(UntranslatedL10n.untranslated, "Untranslated")
        XCTAssertEqual(UntranslatedL10n.untranslatedPlural(5), "5 untranslated items")
    }

    // MARK: - Helpers

    /// Reads a value straight from one language's Untranslated table, or nil when that table lacks the key.
    private func untranslatedValue(_ key: String, language: String) -> String? {
        guard let bundle = Bundle.lprojBundle(for: language) else { return nil }
        let value = bundle.localizedString(forKey: key, value: nil, table: "Untranslated")
        return value == key ? nil : value
    }
}
