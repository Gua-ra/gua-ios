//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import XCTest

@MainActor
class PhoneEntryScreenViewModelTests: XCTestCase {
    var viewModel: PhoneEntryScreenViewModel!

    var context: PhoneEntryScreenViewModelType.Context {
        viewModel.context
    }

    override func setUpWithError() throws {
        viewModel = PhoneEntryScreenViewModel(isLegacyAuthEnabled: false)
    }

    func testInitialState() {
        XCTAssertTrue(context.viewState.bindings.localPhoneNumber.isEmpty)
        XCTAssertFalse(context.viewState.canContinue)
        XCTAssertFalse(context.viewState.isLegacyAuthEnabled)
        XCTAssertFalse(context.viewState.selectedCountry.dialCode.isEmpty)
    }

    func testValidation() {
        XCTAssertFalse(PhoneEntryScreenViewState.isValid(localDigits: "", dialCode: "1"))
        XCTAssertFalse(PhoneEntryScreenViewState.isValid(localDigits: "123", dialCode: "1"))
        XCTAssertTrue(PhoneEntryScreenViewState.isValid(localDigits: "5551234567", dialCode: "1"))
        XCTAssertTrue(PhoneEntryScreenViewState.isValid(localDigits: "11987654321", dialCode: "55"))
        XCTAssertFalse(PhoneEntryScreenViewState.isValid(localDigits: "12345678901234", dialCode: "12"))
    }

    func testContinueEmitsE164PhoneNumber() async throws {
        viewModel = PhoneEntryScreenViewModel(isLegacyAuthEnabled: false, initialPhoneNumber: "+15551234567")
        let deferred = deferFulfillment(viewModel.actionsPublisher) { action in
            if case .continue(let number) = action, number == "+15551234567" { return true }
            return false
        }
        context.send(viewAction: .continueTapped)
        try await deferred.fulfill()
    }

    func testSignInWithPasskeyTappedEmitsAction() async throws {
        XCTAssertTrue(context.viewState.bindings.localPhoneNumber.isEmpty)
        XCTAssertFalse(context.viewState.canContinue)
        let deferred = deferFulfillment(viewModel.actionsPublisher) { action in
            if case .signInWithPasskey = action { return true }
            return false
        }
        context.send(viewAction: .signInWithPasskeyTapped)
        try await deferred.fulfill()
        XCTAssertTrue(context.viewState.isSubmitting)
    }

    func testInitialPhoneNumberParsesCountry() {
        viewModel = PhoneEntryScreenViewModel(isLegacyAuthEnabled: false, initialPhoneNumber: "+5511987654321")
        XCTAssertEqual(context.viewState.selectedCountry.isoCode, "BR")
        XCTAssertEqual(context.viewState.bindings.localPhoneNumber, "(11) 98765-4321")
    }

    func testCountrySelectionUpdatesStateAndDismissesPicker() throws {
        context.isCountryPickerPresented = true
        let germany = try XCTUnwrap(Country.find(isoCode: "DE"))
        context.send(viewAction: .countrySelected(germany))
        XCTAssertEqual(context.viewState.selectedCountry, germany)
        XCTAssertFalse(context.viewState.bindings.isCountryPickerPresented)
    }

    // MARK: - Autofill / paste country-code stripping (live input path)

    private func enterPhone(_ value: String) {
        context.localPhoneNumber = value
        context.send(viewAction: .phoneNumberChanged)
    }

    func testAutofillInternationalNumberStripsCountryCode() throws {
        try context.send(viewAction: .countrySelected(XCTUnwrap(Country.find(isoCode: "US"))))
        enterPhone("+15551234567")
        XCTAssertTrue(["US", "CA"].contains(context.viewState.selectedCountry.isoCode))
        XCTAssertEqual(context.viewState.localDigits, "5551234567")
        XCTAssertEqual(context.viewState.e164PhoneNumber, "+15551234567")
        XCTAssertTrue(context.viewState.canContinue)
    }

    func testAutofillRedundantDialCodeWithoutPlusStrips() throws {
        try context.send(viewAction: .countrySelected(XCTUnwrap(Country.find(isoCode: "US"))))
        enterPhone("15551234567")
        XCTAssertTrue(["US", "CA"].contains(context.viewState.selectedCountry.isoCode))
        XCTAssertEqual(context.viewState.localDigits, "5551234567")
        XCTAssertEqual(context.viewState.e164PhoneNumber, "+15551234567")
        XCTAssertTrue(context.viewState.canContinue)
    }

    func testAutofillFormattedInternationalNumberStrips() throws {
        try context.send(viewAction: .countrySelected(XCTUnwrap(Country.find(isoCode: "US"))))
        enterPhone("+1 (555) 123-4567")
        XCTAssertEqual(context.viewState.localDigits, "5551234567")
        XCTAssertEqual(context.viewState.e164PhoneNumber, "+15551234567")
        XCTAssertTrue(context.viewState.canContinue)
    }

    func testAutofillBrazilInternationalSwitchesCountry() throws {
        try context.send(viewAction: .countrySelected(XCTUnwrap(Country.find(isoCode: "US"))))
        enterPhone("+5511912345678")
        XCTAssertEqual(context.viewState.selectedCountry.isoCode, "BR")
        XCTAssertEqual(context.viewState.localDigits, "11912345678")
        XCTAssertEqual(context.viewState.e164PhoneNumber, "+5511912345678")
        XCTAssertTrue(context.viewState.canContinue)
    }

    func testInternationalCanadianAreaCodeAutoSwitchesToCanada() throws {
        try context.send(viewAction: .countrySelected(XCTUnwrap(Country.find(isoCode: "US"))))
        enterPhone("+14165551234")
        XCTAssertEqual(context.viewState.selectedCountry.isoCode, "CA")
        XCTAssertEqual(context.viewState.localDigits, "4165551234")
        XCTAssertEqual(context.viewState.e164PhoneNumber, "+14165551234")
    }

    func testNormalLocalNumberIsNotStripped() throws {
        try context.send(viewAction: .countrySelected(XCTUnwrap(Country.find(isoCode: "US"))))
        enterPhone("5551234567")
        XCTAssertEqual(context.viewState.selectedCountry.isoCode, "US")
        XCTAssertEqual(context.viewState.localDigits, "5551234567")
        XCTAssertEqual(context.viewState.e164PhoneNumber, "+15551234567")
        XCTAssertTrue(context.viewState.canContinue)
    }

    // MARK: - Country.normalize unit tests

    func testNormalizeInternationalPlus() throws {
        let us = try XCTUnwrap(Country.find(isoCode: "US"))
        let result = Country.normalize(rawInput: "+15551234567", current: us)
        XCTAssertTrue(["US", "CA"].contains(result.country.isoCode))
        XCTAssertEqual(result.localDigits, "5551234567")
    }

    func testNormalizeRedundantDialCodeNoPlus() throws {
        let us = try XCTUnwrap(Country.find(isoCode: "US"))
        let result = Country.normalize(rawInput: "15551234567", current: us)
        XCTAssertEqual(result.country.isoCode, "US")
        XCTAssertEqual(result.localDigits, "5551234567")
    }

    func testNormalizeBrazilInternational() throws {
        let us = try XCTUnwrap(Country.find(isoCode: "US"))
        let result = Country.normalize(rawInput: "+5511912345678", current: us)
        XCTAssertEqual(result.country.isoCode, "BR")
        XCTAssertEqual(result.localDigits, "11912345678")
    }

    func testNormalizeNormalLocalUnchanged() throws {
        let us = try XCTUnwrap(Country.find(isoCode: "US"))
        let result = Country.normalize(rawInput: "5551234567", current: us)
        XCTAssertEqual(result.country.isoCode, "US")
        XCTAssertEqual(result.localDigits, "5551234567")
    }

    func testNormalizeDoesNotFalseStripCoincidentalLeadingDigits() throws {
        let br = try XCTUnwrap(Country.find(isoCode: "BR"))
        let result = Country.normalize(rawInput: "5555999999999", current: br)
        XCTAssertEqual(result.country.isoCode, "BR")
        XCTAssertEqual(result.localDigits, "5555999999999")
    }

    func testNormalizeShortLocalWithMatchingPrefixNotStripped() throws {
        let br = try XCTUnwrap(Country.find(isoCode: "BR"))
        let result = Country.normalize(rawInput: "55999999999", current: br)
        XCTAssertEqual(result.country.isoCode, "BR")
        XCTAssertEqual(result.localDigits, "55999999999")
    }

    func testNationalDigitLength() {
        XCTAssertEqual(Country.find(isoCode: "US")?.nationalDigitLength, 10)
        XCTAssertEqual(Country.find(isoCode: "BR")?.nationalDigitLength, 11)
    }
}
