//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum TwoStepVerificationScreenViewModelAction {
    case close
    case setUpPasskey
    case setUpPin
}

enum TwoStepVerificationScreenPhase: Equatable {
    case loading
    case overview
    case enteringPhone
    case enteringCurrent
    case enteringOtp
    case enteringNew
    case confirmingNew
    case submitting
}

struct TwoStepVerificationScreenViewState: BindableState {
    static let pinLength = 6
    static let otpLength = 6

    var phase: TwoStepVerificationScreenPhase = .loading
    /// `nil` means the status could not be read, never that nothing is registered.
    var factors: AccountSecurityStatus?
    var phone = ""
    var selectedCountry: Country = .deviceDefault
    var currentPin = ""
    var challengeId: String?
    var otpCode = ""
    var stagedNewPin = ""
    var errorMessage: String?
    var bindings = TwoStepVerificationScreenViewStateBindings()

    var hasPin: Bool {
        factors?.hasPin ?? false
    }

    var passkeyRegistered: Bool {
        factors?.passkeyRegistered ?? false
    }

    var titleKey: String {
        switch phase {
        case .loading, .overview, .submitting:
            return L10n.screenTwoStepVerificationTitle
        case .enteringPhone:
            return L10n.screenTwoStepVerificationPhoneHeader
        case .enteringCurrent:
            return L10n.screenTwoStepVerificationCurrentHeader
        case .enteringOtp:
            return L10n.screenTwoStepVerificationOtpHeader
        case .enteringNew:
            return L10n.screenTwoStepVerificationNewHeader
        case .confirmingNew:
            return L10n.screenTwoStepVerificationConfirmHeader
        }
    }

    var footerKey: String {
        switch phase {
        case .enteringPhone:
            return L10n.screenTwoStepVerificationPhoneFooter
        case .enteringCurrent:
            return L10n.screenTwoStepVerificationCurrentFooter
        case .enteringOtp:
            return L10n.screenTwoStepVerificationOtpFooter
        case .enteringNew:
            return L10n.screenTwoStepVerificationNewFooter
        case .confirmingNew:
            return L10n.screenTwoStepVerificationConfirmFooter
        default:
            return ""
        }
    }

    var canContinue: Bool {
        switch phase {
        case .enteringPhone:
            return Self.isValid(phone: e164PhoneNumber) && !isWorking
        case .enteringCurrent, .enteringNew, .confirmingNew:
            return Self.isValid(pin: bindings.pin) && !isWorking
        case .enteringOtp:
            return Self.isValid(otp: bindings.pin) && !isWorking
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
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("+") else { return false }
        let digits = trimmed.dropFirst()
        return digits.count >= 8 && digits.count <= 15 && digits.allSatisfy(\.isNumber)
    }
}

struct TwoStepVerificationScreenViewStateBindings {
    /// Shared by every 6-digit field, including the OTP.
    var pin = ""
    var localPhoneNumber = ""
    var isCountryPickerPresented = false
}

enum TwoStepVerificationScreenViewAction {
    case startSetup
    case startChange
    case retryStatus
    case pinChanged
    case phoneChanged
    case countrySelected(Country)
    case continueTapped
    case cancelEntry
    case setUpPasskey
}
