//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

final class LocalizationTests {
    deinit {
        Bundle.overrideLocalizations = nil
    }
    
    /// Test ElementL10n considers app language changes
    @Test
    func appLanguage() {
        // set app language to English
        Bundle.overrideLocalizations = ["en"]
        
        #expect(L10n.testLanguageIdentifier == "en")
        
        // set app language to French
        Bundle.overrideLocalizations = ["fr"]
        
        #expect(L10n.testLanguageIdentifier == "fr")
    }
    
    /// Test fallback language for a language not supported at all
    @Test
    func fallbackOnNotSupportedLanguage() {
        //  set app language to something Element don't support at all (chose non existing identifier)
        Bundle.overrideLocalizations = ["xx"]
        
        #expect(L10n.testLanguageIdentifier == "en")
    }
    
    /// Test fallback language for a language supported but poorly translated
    @Test
    func fallbackOnNotTranslatedKey() {
        //  set app language to something Element supports but use a key that is not translated (we have a key that should never be translated)
        Bundle.overrideLocalizations = ["fr"]
        
        #expect(L10n.testLanguageIdentifier == "fr")
        #expect(L10n.testUntranslatedDefaultLanguageIdentifier == "en")
    }
    
    /// Test plurals that ElementL10n considers app language changes
    @Test
    func plurals() {
        //  set app language to English
        Bundle.overrideLocalizations = ["en"]
        
        #expect(L10n.commonMemberCount(1) == "1 Member")
        #expect(L10n.commonMemberCount(2) == "2 Members")
        
        //  set app language to Brazilian Portuguese
        Bundle.overrideLocalizations = ["pt-BR"]
        
        #expect(L10n.commonMemberCount(1) == "1 membro")
        #expect(L10n.commonMemberCount(2) == "2 membros")
    }
    
    /// Test plurals fallback language for a language not supported at all
    @Test
    func pluralsFallbackOnNotSupportedLanguage() {
        //  set app language to something Element don't support at all ("invalid identifier")
        Bundle.overrideLocalizations = ["xx"]
        
        #expect(L10n.commonMemberCount(1) == "1 Member")
        #expect(L10n.commonMemberCount(2) == "2 Members")
    }
    
    @Test
    func shippedLanguagesResolve() throws {
        #expect(Set(Bundle.app.localizations) == ["en", "pt-BR", "pt", "es", "fr"])
        
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
            #expect(resolved.first == expectation.language, "\(expectation.preferences)")
        }
        
        let brazilian = try #require(untranslatedValue("gua_sign_in_with_passkey", language: "pt-BR"))
        #expect(untranslatedValue("gua_sign_in_with_passkey", language: "pt") == brazilian)
    }
    
    /// Test untranslated strings
    @Test
    func untranslated() {
        #expect(UntranslatedL10n.untranslated == "Untranslated")
        #expect(UntranslatedL10n.untranslatedPlural(1) == "One untranslated item")
        #expect(UntranslatedL10n.untranslatedPlural(5) == "5 untranslated items")
    }
    
    @Test
    func untranslatedFollowsAppLanguage() throws {
        let english = try #require(untranslatedValue("gua_sign_in_with_passkey", language: "en"))
        
        for language in ["pt-BR", "es", "fr"] {
            Bundle.overrideLocalizations = [language]
            
            let expected = try #require(untranslatedValue("gua_sign_in_with_passkey", language: language))
            #expect(expected != english, "\(language) has no translation for gua_sign_in_with_passkey")
            #expect(UntranslatedL10n.guaSignInWithPasskey == expected)
        }
        
        Bundle.overrideLocalizations = ["xx"]
        #expect(UntranslatedL10n.guaSignInWithPasskey == english)
    }
    
    @Test
    func untranslatedFallsBackForMissingKey() {
        Bundle.overrideLocalizations = ["pt-BR"]
        
        #expect(untranslatedValue("untranslated", language: "pt-BR") == nil)
        #expect(UntranslatedL10n.untranslated == "Untranslated")
        #expect(UntranslatedL10n.untranslatedPlural(5) == "5 untranslated items")
    }
    
    @Test
    func identityServiceErrorsFollowAppLanguage() {
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
                #expect(description != nil)
                #expect(description != englishDescription, "\(language): \(error)")
                #expect(!(description?.contains("Internal server error") ?? true))
            }
        }
        
        Bundle.overrideLocalizations = ["pt-BR"]
        #expect(IdentityServiceError.pinLocked(retryAfterSeconds: 120).errorDescription == "Você errou o PIN muitas vezes. Tente novamente em 2 minutos.")
    }
    
    @Test
    func durationsFollowAppLanguage() {
        Bundle.overrideLocalizations = ["pt-BR"]
        #expect(IdentityServiceError.humanReadableDuration(seconds: 30) == "1 minuto")
        #expect(IdentityServiceError.humanReadableDuration(seconds: 5 * 3600) == "5 horas")
        #expect(IdentityServiceError.humanReadableDuration(seconds: 86400) == "1 dia")
        
        Bundle.overrideLocalizations = ["fr"]
        #expect(IdentityServiceError.humanReadableDuration(seconds: 3 * 86400) == "3 jours")
        
        Bundle.overrideLocalizations = ["en"]
        #expect(IdentityServiceError.humanReadableDuration(seconds: 3600) == "1 hour")
        #expect(IdentityServiceError.humanReadableDuration(seconds: 7 * 60) == "7 minutes")
    }
    
    private func untranslatedValue(_ key: String, language: String) -> String? {
        guard let bundle = Bundle.lprojBundle(for: language) else { return nil }
        let value = bundle.localizedString(forKey: key, value: nil, table: "Untranslated")
        return value == key ? nil : value
    }
}
