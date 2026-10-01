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
// On intro Continue the screen reads `GET /security/pin/status` and routes on what the account has
// registered:
//   - none of the factors a phone change accepts -> ``stepUpRequired``, a hard block that offers
//     passkey or PIN setup. Checked first, so an account that cannot finish is never texted.
//   - only the PIN, and it is inside the fresh-2FA hold -> ``cooldown``. A passkey holder is not held.
//   - otherwise -> ``currentPhone``, ``reauth``, ``newPhone``, the step-up (passkey assertion when
//     this device can produce one, else ``pin``), ``otp``, ``done``. The endpoint behind each step is
//     documented on the view-model method that calls it.
//
// Two orderings must survive any edit here. Nothing is sent to the new number until the server has
// accepted a step-up inside `POST /account/phone/change/start`. And `403 step_up_required` ends the
// operation: there is no fallback to the reauth token, which only proved an SMS to a number a
// SIM-swap attacker may already hold.

enum ChangePhoneScreenViewModelAction {
    case close
    /// The account can produce no accepted step-up factor and the user chose how to fix that.
    /// Carries the factor they picked, because a passkey is the preferred one and this is not a
    /// funnel into PIN setup.
    case setUpStepUpFactor(AuthFactor)
}

/// Why the flow stopped at ``ChangePhoneScreenPhase/stepUpRequired``. Both are about what can be
/// produced, and neither is ever reported to the server.
enum ChangePhoneStepUpBlockReason: Equatable {
    /// The account holds no factor a phone change accepts.
    case noFactorRegistered
    /// The account holds a passkey, this device could not produce an assertion from it, and there
    /// is no PIN underneath to fall back to.
    case passkeyUnusableHere
}

enum ChangePhoneScreenPhase: Equatable {
    case intro
    /// Hard block: two-step verification has to exist before the number can move. Offers both ways
    /// to create it rather than only the PIN.
    case stepUpRequired
    /// The factor the account would spend is too new to spend yet (fresh-2FA hold), or the account
    /// changed its number too recently (per-account cooldown). Both land here; both expire on
    /// their own.
    case cooldown
    /// The number the account is on today. It is a proof, not a convenience: the server compares
    /// its digest with the account's own directory binding and refuses anything else, so no code is
    /// sent until the person can say which number they are on.
    case currentPhone
    /// Six-digit code from the OTP sent to the CURRENT number, exchanged for the reauth token.
    case reauth
    case newPhone
    /// The account PIN as the step-up factor, reached when no passkey assertion was produced.
    case pin
    /// Six-digit code from the OTP sent to the NEW number.
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
    /// The current number the user typed, kept for the whole attempt because both reauth calls take
    /// it: the server stores nothing between them and re-derives the digest from what is submitted.
    var currentPhoneE164 = ""
    /// Single-use PHONE_CHANGE-scoped reauth token from `/account/reauth/verify`. Spent by
    /// `/account/phone/change/start`; when it expires the flow restarts at ``reauth``.
    var reauthToken = ""
    /// Challenge id from `/account/phone/change/start`, redeemed with the new-number OTP.
    var challengeID = ""
    /// The step-up factors this account can be offered, strongest first, as published by the
    /// server for this operation and filtered to the ones the account holds.
    var stepUpFactors: [AuthFactor] = []
    /// Set when the SERVER refused this flow's passkey leg, as opposed to this device failing to
    /// produce an assertion. The credential is registered and the ceremony did run, so repeating it
    /// would walk into the identical refusal and the PIN underneath would never get its turn; the
    /// rest of this flow therefore asks for the PIN. It lives and dies with one flow, it only ever
    /// steers which factor the UI asks for, and it is never reported to the server: the fallback is
    /// reachable because the account holds a PIN, not because the client said anything about it.
    var passkeyRefusedByServer = false
    /// Remaining cooldown in seconds; populated when entering the `.cooldown` phase.
    var cooldownRemainingSeconds = 0
    var stepUpBlockReason: ChangePhoneStepUpBlockReason = .noFactorRegistered
    var errorMessage: String?
    var bindings = ChangePhoneScreenViewStateBindings()

    /// Human-readable cooldown message shown on the `.cooldown` interstitial.
    var cooldownMessage: String {
        guard cooldownRemainingSeconds > 0 else {
            return L10n.screenChangePhoneCooldownMessageGeneric
        }
        return L10n.screenChangePhoneCooldownMessage(IdentityServiceError.humanReadableDuration(seconds: cooldownRemainingSeconds))
    }

    /// The body of the hard-block screen. It explains what is missing without ever suggesting the
    /// block can be talked out of.
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

    /// Shared with the other two screens that submit a number for a reauthentication, so all three
    /// refuse the same shapes before anything is spent on them.
    static func isValid(phone: String) -> Bool {
        GuaPhoneNumber.isE164(phone)
    }
}

struct ChangePhoneScreenViewStateBindings {
    /// Used for all three 6-digit fields (reauth OTP, account PIN, new-number OTP).
    var code = ""
    /// Country-formatted local phone digits (dial code excluded), used by both phone steps: the
    /// current number first, then the new one.
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
    /// Tapped one of the two buttons on the `.stepUpRequired` block screen.
    case setUpStepUpFactor(AuthFactor)
}
