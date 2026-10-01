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

    var e164PhoneNumber: String {
        "+" + selectedCountry.dialCode + localDigits
    }

    var canContinue: Bool {
        !isSubmitting && Self.isValid(localDigits: localDigits, dialCode: selectedCountry.dialCode)
    }

    /// Matches the resolver's `+[1-9]\d{6,14}` rule, so a number accepted here is not rejected by `/resolve`.
    static func isValid(localDigits: String, dialCode: String) -> Bool {
        let totalDigits = dialCode.count + localDigits.count
        return localDigits.count >= 4 && totalDigits >= 7 && totalDigits <= 15
    }
}

struct PhoneEntryScreenViewStateBindings {
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
