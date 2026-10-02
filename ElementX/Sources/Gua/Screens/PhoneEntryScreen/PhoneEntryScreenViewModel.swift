//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

typealias PhoneEntryScreenViewModelType = StateStoreViewModelV2<PhoneEntryScreenViewState, PhoneEntryScreenViewAction>

class PhoneEntryScreenViewModel: PhoneEntryScreenViewModelType, PhoneEntryScreenViewModelProtocol {
    private let actionsSubject: PassthroughSubject<PhoneEntryScreenViewModelAction, Never> = .init()
    var actionsPublisher: AnyPublisher<PhoneEntryScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(isLegacyAuthEnabled: Bool, initialPhoneNumber: String = "") {
        let (country, localDigits) = Self.parse(initialPhoneNumber: initialPhoneNumber)
        let formatted = country.formatNational(digits: localDigits)
        super.init(initialViewState: PhoneEntryScreenViewState(isLegacyAuthEnabled: isLegacyAuthEnabled,
                                                               selectedCountry: country,
                                                               bindings: .init(localPhoneNumber: formatted)))
    }

    // MARK: - Public

    func setSubmitting(_ isSubmitting: Bool) {
        state.isSubmitting = isSubmitting
        if isSubmitting { state.errorMessage = nil }
    }

    func displayError(_ message: String) {
        state.isSubmitting = false
        state.errorMessage = message
    }

    override func process(viewAction: PhoneEntryScreenViewAction) {
        switch viewAction {
        case .continueTapped:
            guard state.canContinue else { return }
            state.isSubmitting = true
            actionsSubject.send(.continue(phoneNumber: state.e164PhoneNumber))
        case .signInWithPasskeyTapped:
            state.isSubmitting = true
            actionsSubject.send(.signInWithPasskey)
        case .useLegacyAuthTapped:
            actionsSubject.send(.useLegacyAuth)
        case .countrySelected(let country):
            state.selectedCountry = country
            state.bindings.isCountryPickerPresented = false
            reformatNumber()
        case .phoneNumberChanged:
            normalizeInput()
            autoDetectCountry()
            reformatNumber()
        }
    }

    /// Detects a country code pasted or autofilled into the local field, switches the country and
    /// strips the code. Must run before `autoDetectCountry()` and `reformatNumber()`, which expect the
    /// stripped digits.
    private func normalizeInput() {
        let raw = state.bindings.localPhoneNumber
        let (country, localDigits) = Country.normalize(rawInput: raw, current: state.selectedCountry)
        if country != state.selectedCountry {
            state.selectedCountry = country
        }
        // Only rewrite the field when stripping changed the digits, so in-progress formatting is not
        // clobbered on every keystroke.
        if localDigits != raw.filter(\.isNumber) {
            state.bindings.localPhoneNumber = localDigits
        }
    }

    /// Rewrites the field with the country's live format. The cursor jumps to the end on each
    /// reformat, an accepted trade-off for phone entry.
    private func reformatNumber() {
        let digits = state.bindings.localPhoneNumber.filter(\.isNumber)
        let formatted = state.selectedCountry.formatNational(digits: digits)
        if formatted != state.bindings.localPhoneNumber {
            state.bindings.localPhoneNumber = formatted
        }
    }

    private func autoDetectCountry() {
        if let detected = Country.detect(localDigits: state.localDigits,
                                         current: state.selectedCountry) {
            state.selectedCountry = detected
        }
    }

    // MARK: - Private

    /// Splits an optional pre-populated E.164 number into (country, localDigits).
    /// Falls back to the device's locale when the input is empty or unparseable.
    private static func parse(initialPhoneNumber: String) -> (Country, String) {
        let trimmed = initialPhoneNumber.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("+") else { return (Country.deviceDefault, "") }

        let digits = String(trimmed.dropFirst()).filter(\.isNumber)
        // Longest-prefix match: some dial codes are 4 digits, e.g. +1876 for Jamaica.
        for length in stride(from: min(4, digits.count), through: 1, by: -1) {
            let prefix = String(digits.prefix(length))
            if let country = Country.all.first(where: { $0.dialCode == prefix }) {
                return (country, String(digits.dropFirst(length)))
            }
        }
        return (Country.deviceDefault, digits)
    }
}
