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
// The contract is the identity service's account endpoints. On intro Continue the screen reads
// `GET /security/pin/status`, which reports what the account HAS REGISTERED and which factors a
// phone change accepts, and that report is what decides the route:
//   • the account can offer none of the accepted factors → ``stepUpRequired``, a hard block that
//     offers a choice between setting up a passkey and setting up a PIN. Deliberately first, so an
//     account that cannot finish the flow is never texted anything at all.
//   • the only factor it can offer is the PIN and that PIN is still inside the fresh-2FA hold
//     (`changePhoneCooldownRemainingSeconds`) → ``cooldown``. The hold is about the PIN, so an
//     account that can offer a passkey is not held by it.
//   • otherwise → ``reauth`` and onward.
// Flow:
//   ``intro`` → ``reauth`` (`POST /account/reauth/start` texts the CURRENT number, then
//      `/account/reauth/verify` scoped to PHONE_CHANGE mints a single-use token)
//   → ``newPhone`` (country-aware entry of the new number)
//   → the step-up, strongest factor first: a user-verifying passkey assertion from
//      `POST /security/passkey/stepup/options` when this device can produce one, otherwise the
//      account PIN at ``pin``
//   → `POST /account/phone/change/start`, which spends the reauth token and the step-up together
//      and only then texts the NEW number
//   → ``otp`` (the code that arrived there; `POST /account/phone/change/complete` re-binds
//      atomically) → ``done``.
//
// Two orderings are load-bearing and must survive any edit here. Nothing is sent to the new number
// until a step-up has actually been accepted, which is the server's own sequencing inside
// `/start`. And the hard block is hard: `403 step_up_required` ends the operation rather than
// falling back to the reauth token, which only ever proved an SMS to a number a SIM-swap attacker
// may already hold.

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
    /// Single-use PHONE_CHANGE-scoped reauth token from `/account/reauth/verify`. Spent by
    /// `/account/phone/change/start`; when it expires the flow restarts at ``reauth``.
    var reauthToken = ""
    /// Challenge id from `/account/phone/change/start`, redeemed with the new-number OTP.
    var challengeID = ""
    /// The step-up factors this account can be offered, strongest first, as published by the
    /// server for this operation and filtered to the ones the account holds.
    var stepUpFactors: [AuthFactor] = []
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
        case .newPhone:
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

    static func isValid(phone: String) -> Bool {
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("+") else { return false }
        let digits = trimmed.dropFirst()
        return digits.count >= 8 && digits.count <= 15 && digits.allSatisfy(\.isNumber)
    }
}

struct ChangePhoneScreenViewStateBindings {
    /// Used for all three 6-digit fields (reauth OTP, account PIN, new-number OTP).
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
    /// Tapped one of the two buttons on the `.stepUpRequired` block screen.
    case setUpStepUpFactor(AuthFactor)
}
