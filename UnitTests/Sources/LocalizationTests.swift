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

        // set app language to French
        Bundle.overrideLocalizations = ["fr"]

        XCTAssertEqual(L10n.testLanguageIdentifier, "fr")
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
        Bundle.overrideLocalizations = ["fr"]

        XCTAssertEqual(L10n.testLanguageIdentifier, "fr")
        XCTAssertEqual(L10n.testUntranslatedDefaultLanguageIdentifier, "en")
    }

    /// Test plurals that ElementL10n considers app language changes
    func testPlurals() {
        //  set app language to English
        Bundle.overrideLocalizations = ["en"]

        XCTAssertEqual(L10n.commonMemberCount(1), "1 Member")
        XCTAssertEqual(L10n.commonMemberCount(2), "2 Members")

        //  set app language to Brazilian Portuguese
        Bundle.overrideLocalizations = ["pt-BR"]

        XCTAssertEqual(L10n.commonMemberCount(1), "1 membro")
        XCTAssertEqual(L10n.commonMemberCount(2), "2 membros")
    }

    /// Test plurals fallback language for a language not supported at all
    func testPluralsFallbackOnNotSupportedLanguage() {
        //  set app language to something Element don't support at all ("invalid identifier")
        Bundle.overrideLocalizations = ["xx"]

        XCTAssertEqual(L10n.commonMemberCount(1), "1 Member")
        XCTAssertEqual(L10n.commonMemberCount(2), "2 Members")
    }

    func testShippedLanguagesResolve() throws {
        XCTAssertEqual(Set(Bundle.app.localizations), ["en", "pt-BR", "pt", "es", "fr"])

        let expectations: [(preferences: [String], language: String)] = [(["pt-BR"], "pt-BR"),
                                                                         (["pt-BR", "en"], "pt-BR"),
                                                                         (["pt"], "pt"),
                                                                         (["pt-PT"], "pt"),
                                                                         (["pt-PT", "en"], "pt"),
                                                                         (["pt-PT", "en-CA"], "pt"),
                                                                         (["es-MX"], "es"),
                                                                         (["fr-CA"], "fr"),
                                                                         (["en-US"], "en"),
                                                                         (["de"], "en"),
                                                                         (["ja"], "en")]
        for expectation in expectations {
            let resolved = Bundle.preferredLocalizations(from: Bundle.app.localizations, forPreferences: expectation.preferences)
            XCTAssertEqual(resolved.first, expectation.language, "\(expectation.preferences)")
        }

        let brazilian = try XCTUnwrap(untranslatedValue("gua_sign_in_with_passkey", language: "pt-BR"))
        XCTAssertEqual(untranslatedValue("gua_sign_in_with_passkey", language: "pt"), brazilian)
    }

    /// Test untranslated strings
    func testUntranslated() {
        XCTAssertEqual(UntranslatedL10n.untranslated, "Untranslated")
        XCTAssertEqual(UntranslatedL10n.untranslatedPlural(1), "One untranslated item")
        XCTAssertEqual(UntranslatedL10n.untranslatedPlural(5), "5 untranslated items")
    }

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

    func testUntranslatedFallsBackForMissingKey() {
        Bundle.overrideLocalizations = ["pt-BR"]

        XCTAssertNil(untranslatedValue("untranslated", language: "pt-BR"))
        XCTAssertEqual(UntranslatedL10n.untranslated, "Untranslated")
        XCTAssertEqual(UntranslatedL10n.untranslatedPlural(5), "5 untranslated items")
    }

    func testIdentityServiceErrorsFollowAppLanguage() {
        let errors: [IdentityServiceError] = [.rateLimited,
                                              .pinLocked(retryAfterSeconds: 120),
                                              .pinChangeChallengeInvalid,
                                              .server(status: 500, message: "Internal server error")]

        Bundle.overrideLocalizations = ["en"]
        let english = errors.map(\.errorDescription)

        for language in ["pt-BR", "es", "fr"] {
            Bundle.overrideLocalizations = [language]

            for (error, englishDescription) in zip(errors, english) {
                let description = error.errorDescription
                XCTAssertNotNil(description)
                XCTAssertNotEqual(description, englishDescription, "\(language): \(error)")
                XCTAssertFalse(description?.contains("Internal server error") ?? true)
            }
        }

        Bundle.overrideLocalizations = ["pt-BR"]
        XCTAssertEqual(IdentityServiceError.pinLocked(retryAfterSeconds: 120).errorDescription,
                       "Você errou o PIN muitas vezes. Tente novamente em 2 minutos.")
    }

    func testDurationsFollowAppLanguage() {
        Bundle.overrideLocalizations = ["pt-BR"]
        XCTAssertEqual(IdentityServiceError.humanReadableDuration(seconds: 30), "1 minuto")
        XCTAssertEqual(IdentityServiceError.humanReadableDuration(seconds: 5 * 3600), "5 horas")
        XCTAssertEqual(IdentityServiceError.humanReadableDuration(seconds: 86400), "1 dia")

        Bundle.overrideLocalizations = ["fr"]
        XCTAssertEqual(IdentityServiceError.humanReadableDuration(seconds: 3 * 86400), "3 jours")

        Bundle.overrideLocalizations = ["en"]
        XCTAssertEqual(IdentityServiceError.humanReadableDuration(seconds: 3600), "1 hour")
        XCTAssertEqual(IdentityServiceError.humanReadableDuration(seconds: 7 * 60), "7 minutes")
    }

    private func untranslatedValue(_ key: String, language: String) -> String? {
        guard let bundle = Bundle.lprojBundle(for: language) else { return nil }
        let value = bundle.localizedString(forKey: key, value: nil, table: "Untranslated")
        return value == key ? nil : value
    }
}
