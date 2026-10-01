//
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

// Nothing is sent to the new number until the server accepts a step-up.
// `403 step_up_required` ends the operation: the reauth token alone is never enough.

enum ChangePhoneScreenViewModelAction {
    case close
    case setUpStepUpFactor(AuthFactor)
}

enum ChangePhoneStepUpBlockReason: Equatable {
    case noFactorRegistered
    /// The account holds a passkey this device cannot use, and no PIN.
    case passkeyUnusableHere
}

enum ChangePhoneScreenPhase: Equatable {
    case intro
    case stepUpRequired
    case cooldown
    case currentPhone
    /// Code sent to the current number.
    case reauth
    case newPhone
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
    var currentPhoneE164 = ""
    var reauthToken = ""
    var challengeID = ""
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
