//
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

// GUA FORK: Change-phone-number flow. Mirrors the multi-step structure of the
// TwoStepVerificationScreen (PIN/OTP bubble fields, country-aware phone entry).
//
// Backend contract is single-step (`POST /otp/change-number { userId, newPhone, code, pin }`),
// with the verification OTP delivered to the *new* number via `POST /otp/send` and the account PIN
// acting as the second factor. Flow:
//   ``intro`` → ``newPhone`` (country-aware entry of the new number)
//   → ``pin`` (6-digit account PIN; on submit an OTP is sent to the new number)
//   → ``otp`` (6-digit code from the new number → atomic re-bind) → ``done``.

enum ChangePhoneScreenViewModelAction {
    case close
}

enum ChangePhoneScreenPhase: Equatable {
    case intro
    case newPhone
    case pin
    case otp
    case submitting
    case done
}

struct ChangePhoneScreenViewState: BindableState {
    static let otpLength = 6
    static let pinLength = 6

    var phase: ChangePhoneScreenPhase = .intro
    var selectedCountry: Country = .deviceDefault
    /// The confirmed new number in E.164 form (e.g. "+15551234567").
    var newPhoneE164 = ""
    /// The account PIN captured on the `.pin` step, replayed with the OTP on the final submit.
    var enteredPin = ""
    var errorMessage: String?
    var bindings = ChangePhoneScreenViewStateBindings()

    var titleKey: String {
        switch phase {
        case .intro, .submitting, .done:
            return L10n.screenChangePhoneTitle
        case .newPhone:
            return L10n.screenChangePhoneNewHeader
        case .pin:
            return L10n.screenChangePhonePinHeader
        case .otp:
            return L10n.screenChangePhoneOtpHeader
        }
    }

    var footerKey: String {
        switch phase {
        case .newPhone:
            return L10n.screenChangePhoneNewFooter
        case .pin:
            return L10n.screenChangePhonePinFooter
        case .otp:
            return L10n.screenChangePhoneOtpFooter
        default:
            return ""
        }
    }

    var canContinue: Bool {
        switch phase {
        case .newPhone:
            return Self.isValid(phone: e164PhoneNumber) && !isWorking
        case .pin:
            return Self.isValid(pin: bindings.code) && !isWorking
        case .otp:
            return Self.isValid(otp: bindings.code) && !isWorking
        default:
            return false
        }
    }

    var isWorking: Bool {
        phase == .submitting
    }

    /// Local subscriber digits typed by the user, stripped of any formatting characters.
    var localDigits: String {
        bindings.localPhoneNumber.filter(\.isNumber)
    }

    /// Full E.164 phone number to send to the backend (e.g. "+15551234567").
    var e164PhoneNumber: String {
        "+" + selectedCountry.dialCode + localDigits
    }

    static func isValid(pin: String) -> Bool {
        pin.count == pinLength && pin.allSatisfy(\.isNumber)
    }

    static func isValid(otp: String) -> Bool {
        otp.count == otpLength && otp.allSatisfy(\.isNumber)
    }

    static func isValid(phone: String) -> Bool {
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("+") else { return false }
        let digits = trimmed.dropFirst()
        return digits.count >= 8 && digits.count <= 15 && digits.allSatisfy(\.isNumber)
    }
}

struct ChangePhoneScreenViewStateBindings {
    /// Used for both 6-digit fields (account PIN, new-number OTP).
    var code = ""
    /// Country-formatted local phone digits for the new number (dial code excluded).
    var localPhoneNumber = ""
    var isCountryPickerPresented = false
}

enum ChangePhoneScreenViewAction {
    case start
    case codeChanged
    case phoneChanged
    case countrySelected(Country)
    case continueTapped
    case cancel
    case done
}
