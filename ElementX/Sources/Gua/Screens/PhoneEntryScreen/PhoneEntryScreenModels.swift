//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum PhoneEntryScreenViewModelAction {
    case `continue`(phoneNumber: String)
    case useLegacyAuth
    /// Sign in with a passkey instead of a number. Carries no phone number: the credential is
    /// discoverable, so it identifies the account by itself and no code has to be sent.
    case signInWithPasskey
}

struct PhoneEntryScreenViewState: BindableState {
    var isLegacyAuthEnabled: Bool
    var selectedCountry: Country
    var isSubmitting = false
    var errorMessage: String?

    var bindings: PhoneEntryScreenViewStateBindings

    var localDigits: String {
        bindings.localPhoneNumber.filter(\.isNumber)
    }

    /// Full E.164 phone number to send to the backend (e.g. "+15551234567").
    var e164PhoneNumber: String {
        "+" + selectedCountry.dialCode + localDigits
    }

    var canContinue: Bool {
        !isSubmitting && Self.isValid(localDigits: localDigits, dialCode: selectedCountry.dialCode)
    }

    /// E.164 numbers are 7 to 15 digits including the country code. Matches the resolver's
    /// `+[1-9]\d{6,14}` rule, so a number accepted here is not rejected by `/resolve`. Also requires at
    /// least a 4-digit subscriber part.
    static func isValid(localDigits: String, dialCode: String) -> Bool {
        let totalDigits = dialCode.count + localDigits.count
        return localDigits.count >= 4 && totalDigits >= 7 && totalDigits <= 15
    }
}

struct PhoneEntryScreenViewStateBindings {
    /// Digits typed by the user, excluding the dial code.
    var localPhoneNumber = ""
    var isCountryPickerPresented = false
}

enum PhoneEntryScreenViewAction {
    case continueTapped
    case signInWithPasskeyTapped
    case useLegacyAuthTapped
    case countrySelected(Country)
    case phoneNumberChanged
}
