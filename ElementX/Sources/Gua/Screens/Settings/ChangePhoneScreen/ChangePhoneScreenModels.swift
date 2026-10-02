//
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

// Change-phone-number flow, driven by identity-service's account endpoints.
//
// On intro Continue the screen reads `GET /security/pin/status` and routes on it:
//   - the account holds no accepted factor: `stepUpRequired`, a hard block, before anything is texted.
//   - the only factor is a PIN still inside its hold: `cooldown`.
//   - otherwise: `currentPhone` and onward.
// Flow: `intro` -> `currentPhone` -> `reauth` (`/account/reauth/start` texts the current number only
// if it is the account's own; `/account/reauth/verify` returns a PHONE_CHANGE token) -> `newPhone`
// -> step-up (a passkey assertion when this device can produce one, otherwise `pin`)
// -> `POST /account/phone/change/start` -> `otp` (`/account/phone/change/complete`) -> `done`.
//
// Nothing is sent to the new number until the server accepts a step-up.
// `403 step_up_required` ends the operation: the reauth token alone is never enough.

enum ChangePhoneScreenViewModelAction {
    case close
    case setUpStepUpFactor(AuthFactor)
}

/// Why the flow stopped at `stepUpRequired`. Never reported to the server.
enum ChangePhoneStepUpBlockReason: Equatable {
    /// The account holds no factor a phone change accepts.
    case noFactorRegistered
    /// The account holds a passkey this device cannot use, and no PIN.
    case passkeyUnusableHere
}

enum ChangePhoneScreenPhase: Equatable {
    case intro
    /// Hard block: the account needs a passkey or a PIN before the number can change.
    case stepUpRequired
    /// The factor is too new to use yet, or the number changed too recently. Both expire on their own.
    case cooldown
    /// The number the account is on today. A proof: no code is sent until the server confirms it.
    case currentPhone
    /// Code sent to the current number.
    case reauth
    case newPhone
    /// The account PIN as the step-up factor, reached when no passkey assertion was produced.
    case pin
    /// Code sent to the new number.
    case otp
    case submitting
    case done
}

struct ChangePhoneScreenViewState: BindableState {
    static let otpLength = 6
    static let pinLength = 6

    var phase: ChangePhoneScreenPhase = .intro
    var selectedCountry: Country = .deviceDefault
    var newPhoneE164 = ""
    /// Kept for the whole attempt: both reauth calls take it, because the server stores nothing
    /// between them.
    var currentPhoneE164 = ""
    /// Single-use PHONE_CHANGE-scoped reauth token from `/account/reauth/verify`. Spent by
    /// `/account/phone/change/start`; when it expires the flow restarts at `reauth`.
    var reauthToken = ""
    /// Challenge id from `/account/phone/change/start`, redeemed with the new-number OTP.
    var challengeID = ""
    /// The step-up factors this account can be offered, strongest first.
    var stepUpFactors: [AuthFactor] = []
    /// The server refused this flow's passkey assertion, so the rest of the flow asks for the PIN.
    /// Never sent to the server.
    var passkeyRefusedByServer = false
    var cooldownRemainingSeconds = 0
    var stepUpBlockReason: ChangePhoneStepUpBlockReason = .noFactorRegistered
    var errorMessage: String?
    var bindings = ChangePhoneScreenViewStateBindings()

    var cooldownMessage: String {
        guard cooldownRemainingSeconds > 0 else {
            return L10n.screenChangePhoneCooldownMessageGeneric
        }
        return L10n.screenChangePhoneCooldownMessage(IdentityServiceError.humanReadableDuration(seconds: cooldownRemainingSeconds))
    }

    var stepUpBlockMessage: String {
        switch stepUpBlockReason {
        case .noFactorRegistered: L10n.screenChangePhoneStepUpMessage
        case .passkeyUnusableHere: L10n.screenChangePhoneStepUpPasskeyUnusableMessage
        }
    }

    var titleKey: String {
        switch phase {
        case .intro, .submitting, .done, .stepUpRequired, .cooldown:
            return L10n.screenChangePhoneTitle
        case .newPhone:
            return L10n.screenChangePhoneNewHeader
        case .currentPhone:
            return L10n.screenChangePhoneCurrentHeader
        case .reauth:
            return L10n.screenChangePhoneReauthHeader
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
        case .currentPhone:
            return L10n.screenChangePhoneCurrentFooter
        case .reauth:
            return L10n.screenChangePhoneReauthFooter
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
        case .newPhone, .currentPhone:
            return Self.isValid(phone: e164PhoneNumber) && !isWorking
        case .pin:
            return Self.isValid(pin: bindings.code) && !isWorking
        case .reauth, .otp:
            return Self.isValid(otp: bindings.code) && !isWorking
        default:
            return false
        }
    }

    var isWorking: Bool {
        phase == .submitting
    }

    var localDigits: String {
        bindings.localPhoneNumber.filter(\.isNumber)
    }

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
        GuaPhoneNumber.isE164(phone)
    }
}

struct ChangePhoneScreenViewStateBindings {
    /// Shared by the reauth code, PIN and new-number code fields.
    var code = ""
    /// Local digits (dial code excluded), used by both phone steps: the current number, then the new one.
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
    case setUpStepUpFactor(AuthFactor)
}
