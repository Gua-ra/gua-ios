//
// Copyright 2022-2024 New Vector Ltd.
// Copyright 2025 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

@MainActor
final class PhoneEntryScreenViewModelTests {
    var viewModel: PhoneEntryScreenViewModel!
    
    var context: PhoneEntryScreenViewModelType.Context {
        viewModel.context
    }
    
    init() throws {
        viewModel = PhoneEntryScreenViewModel(isLegacyAuthEnabled: false)
    }
    
    @Test
    func initialState() {
        #expect(context.viewState.bindings.localPhoneNumber.isEmpty)
        #expect(!context.viewState.canContinue)
        #expect(!context.viewState.isLegacyAuthEnabled)
        // Default country comes from device locale; fallback is US.
        #expect(!context.viewState.selectedCountry.dialCode.isEmpty)
    }
    
    @Test
    func validation() {
        #expect(!PhoneEntryScreenViewState.isValid(localDigits: "", dialCode: "1"))
        #expect(!PhoneEntryScreenViewState.isValid(localDigits: "123", dialCode: "1"))
        #expect(PhoneEntryScreenViewState.isValid(localDigits: "5551234567", dialCode: "1"))
        #expect(PhoneEntryScreenViewState.isValid(localDigits: "11987654321", dialCode: "55"))
        // 16-digit total length is rejected (E.164 max is 15).
        #expect(!PhoneEntryScreenViewState.isValid(localDigits: "12345678901234", dialCode: "12"))
    }
    
    @Test
    func continueEmitsE164PhoneNumber() async throws {
        viewModel = PhoneEntryScreenViewModel(isLegacyAuthEnabled: false, initialPhoneNumber: "+15551234567")
        let deferred = deferFulfillment(viewModel.actionsPublisher) { action in
            if case .continue(let number) = action, number == "+15551234567" {
                return true
            }
            return false
        }
        context.send(viewAction: .continueTapped)
        try await deferred.fulfill()
    }
    
    @Test
    func actionsWhileSubmittingEmitNothing() async throws {
        viewModel = PhoneEntryScreenViewModel(isLegacyAuthEnabled: false, initialPhoneNumber: "+15551234567")
        let firstContinue = deferFulfillment(viewModel.actionsPublisher) { _ in true }
        context.send(viewAction: .continueTapped)
        try await firstContinue.fulfill()
        #expect(!context.viewState.canContinue)
        
        let repeatedAction = deferFailure(viewModel.actionsPublisher, timeout: .seconds(1)) { _ in true }
        context.send(viewAction: .continueTapped)
        context.send(viewAction: .signInWithPasskeyTapped)
        context.send(viewAction: .useLegacyAuthTapped)
        try await repeatedAction.fulfill()
    }
    
    @Test
    func signInWithPasskeyTappedEmitsAction() async throws {
        // No number is needed: the credential identifies the account by itself.
        #expect(context.viewState.bindings.localPhoneNumber.isEmpty)
        #expect(!context.viewState.canContinue)
        let deferred = deferFulfillment(viewModel.actionsPublisher) { action in
            if case .signInWithPasskey = action {
                return true
            }
            return false
        }
        context.send(viewAction: .signInWithPasskeyTapped)
        try await deferred.fulfill()
        #expect(context.viewState.isSubmitting)
    }
    
    @Test
    func initialPhoneNumberParsesCountry() {
        viewModel = PhoneEntryScreenViewModel(isLegacyAuthEnabled: false, initialPhoneNumber: "+5511987654321")
        #expect(context.viewState.selectedCountry.isoCode == "BR")
        #expect(context.viewState.bindings.localPhoneNumber == "(11) 98765-4321")
    }
    
    @Test
    func countrySelectionUpdatesStateAndDismissesPicker() throws {
        context.isCountryPickerPresented = true
        let germany = try #require(Country.find(isoCode: "DE"))
        context.send(viewAction: .countrySelected(germany))
        #expect(context.viewState.selectedCountry == germany)
        #expect(!context.viewState.bindings.isCountryPickerPresented)
    }
    
    // MARK: - Autofill / paste country-code stripping (live input path)
    
    /// Drives the live input path the way the text field does: set the bound value, then fire
    /// the change action that runs normalize → autoDetect → reformat.
    private func enterPhone(_ value: String) {
        context.localPhoneNumber = value
        context.send(viewAction: .phoneNumberChanged)
    }
    
    @Test
    func autofillInternationalNumberStripsCountryCode() throws {
        // US is the first +1 entry in `Country.all`, so the start state is the +1 plan.
        try context.send(viewAction: .countrySelected(#require(Country.find(isoCode: "US"))))
        enterPhone("+15551234567")
        #expect(["US", "CA"].contains(context.viewState.selectedCountry.isoCode))
        #expect(context.viewState.localDigits == "5551234567")
        #expect(context.viewState.e164PhoneNumber == "+15551234567")
        #expect(context.viewState.canContinue)
    }
    
    @Test
    func autofillRedundantDialCodeWithoutPlusStrips() throws {
        try context.send(viewAction: .countrySelected(#require(Country.find(isoCode: "US"))))
        // No "+", leading "1" is the redundant country code (11 digits, NANP national is 10).
        enterPhone("15551234567")
        #expect(["US", "CA"].contains(context.viewState.selectedCountry.isoCode))
        #expect(context.viewState.localDigits == "5551234567")
        #expect(context.viewState.e164PhoneNumber == "+15551234567")
        #expect(context.viewState.canContinue)
    }
    
    @Test
    func autofillFormattedInternationalNumberStrips() throws {
        try context.send(viewAction: .countrySelected(#require(Country.find(isoCode: "US"))))
        // iOS contact autofill style with separators and parens.
        enterPhone("+1 (555) 123-4567")
        #expect(context.viewState.localDigits == "5551234567")
        #expect(context.viewState.e164PhoneNumber == "+15551234567")
        #expect(context.viewState.canContinue)
    }
    
    @Test
    func autofillBrazilInternationalSwitchesCountry() throws {
        try context.send(viewAction: .countrySelected(#require(Country.find(isoCode: "US"))))
        enterPhone("+5511912345678")
        #expect(context.viewState.selectedCountry.isoCode == "BR")
        #expect(context.viewState.localDigits == "11912345678")
        #expect(context.viewState.e164PhoneNumber == "+5511912345678")
        #expect(context.viewState.canContinue)
    }
    
    @Test
    func internationalCanadianAreaCodeAutoSwitchesToCanada() throws {
        try context.send(viewAction: .countrySelected(#require(Country.find(isoCode: "US"))))
        // 416 is a Canadian area code; country should flip to CA after stripping "+1".
        enterPhone("+14165551234")
        #expect(context.viewState.selectedCountry.isoCode == "CA")
        #expect(context.viewState.localDigits == "4165551234")
        #expect(context.viewState.e164PhoneNumber == "+14165551234")
    }
    
    @Test
    func normalLocalNumberIsNotStripped() throws {
        try context.send(viewAction: .countrySelected(#require(Country.find(isoCode: "US"))))
        enterPhone("5551234567")
        #expect(context.viewState.selectedCountry.isoCode == "US")
        #expect(context.viewState.localDigits == "5551234567")
        #expect(context.viewState.e164PhoneNumber == "+15551234567")
        #expect(context.viewState.canContinue)
    }
    
    // MARK: - Country.normalize unit tests
    
    @Test
    func normalizeInternationalPlus() throws {
        let us = try #require(Country.find(isoCode: "US"))
        let result = Country.normalize(rawInput: "+15551234567", current: us)
        #expect(["US", "CA"].contains(result.country.isoCode))
        #expect(result.localDigits == "5551234567")
    }
    
    @Test
    func normalizeRedundantDialCodeNoPlus() throws {
        let us = try #require(Country.find(isoCode: "US"))
        let result = Country.normalize(rawInput: "15551234567", current: us)
        #expect(result.country.isoCode == "US")
        #expect(result.localDigits == "5551234567")
    }
    
    @Test
    func normalizeBrazilInternational() throws {
        let us = try #require(Country.find(isoCode: "US"))
        let result = Country.normalize(rawInput: "+5511912345678", current: us)
        #expect(result.country.isoCode == "BR")
        #expect(result.localDigits == "11912345678")
    }
    
    @Test
    func normalizeNormalLocalUnchanged() throws {
        let us = try #require(Country.find(isoCode: "US"))
        let result = Country.normalize(rawInput: "5551234567", current: us)
        #expect(result.country.isoCode == "US")
        #expect(result.localDigits == "5551234567")
    }
    
    @Test
    func normalizeDoesNotFalseStripCoincidentalLeadingDigits() throws {
        // BR DDD 55 (Santa Maria) typed WITH a redundant +55: remainder still begins with the
        // dial code, so it's ambiguous and must be left untouched.
        let br = try #require(Country.find(isoCode: "BR"))
        let result = Country.normalize(rawInput: "5555999999999", current: br)
        #expect(result.country.isoCode == "BR")
        #expect(result.localDigits == "5555999999999")
    }
    
    @Test
    func normalizeShortLocalWithMatchingPrefixNotStripped() throws {
        // A genuine BR local number whose DDD starts with "55" must not be stripped: the total
        // length doesn't match dialCode + national length, so there's no redundancy.
        let br = try #require(Country.find(isoCode: "BR"))
        let result = Country.normalize(rawInput: "55999999999", current: br)
        #expect(result.country.isoCode == "BR")
        #expect(result.localDigits == "55999999999")
    }
    
    @Test
    func nationalDigitLength() {
        #expect(Country.find(isoCode: "US")?.nationalDigitLength == 10)
        #expect(Country.find(isoCode: "BR")?.nationalDigitLength == 11)
    }
}
