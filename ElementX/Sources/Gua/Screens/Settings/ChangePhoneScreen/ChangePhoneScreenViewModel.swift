//
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

typealias ChangePhoneScreenViewModelType = StateStoreViewModelV2<ChangePhoneScreenViewState, ChangePhoneScreenViewAction>

class ChangePhoneScreenViewModel: ChangePhoneScreenViewModelType, ChangePhoneScreenViewModelProtocol {
    private let clientProxy: ClientProxyProtocol
    private let identityServiceClient: IdentityServiceClientProtocol
    private let userIndicatorController: UserIndicatorControllerProtocol

    private let actionsSubject: PassthroughSubject<ChangePhoneScreenViewModelAction, Never> = .init()
    var actionsPublisher: AnyPublisher<ChangePhoneScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    private let indicatorID = "ChangePhoneScreen-Submit"
    private let successIndicatorID = "ChangePhoneScreen-Success"

    init(clientProxy: ClientProxyProtocol,
         identityServiceClient: IdentityServiceClientProtocol,
         userIndicatorController: UserIndicatorControllerProtocol) {
        self.clientProxy = clientProxy
        self.identityServiceClient = identityServiceClient
        self.userIndicatorController = userIndicatorController

        super.init(initialViewState: ChangePhoneScreenViewState())
    }

    override func process(viewAction: ChangePhoneScreenViewAction) {
        switch viewAction {
        case .start:
            state.selectedCountry = .deviceDefault
            state.errorMessage = nil
            state.phase = .newPhone
        case .phoneChanged:
            normalizeInput()
            autoDetectCountry()
            reformatNumber()
            if state.errorMessage != nil { state.errorMessage = nil }
        case .countrySelected(let country):
            state.selectedCountry = country
            state.bindings.isCountryPickerPresented = false
            reformatNumber()
        case .codeChanged:
            let length = currentCodeLength
            let cleaned = String(state.bindings.code.filter(\.isNumber).prefix(length))
            if cleaned != state.bindings.code {
                state.bindings.code = cleaned
            }
            if state.errorMessage != nil { state.errorMessage = nil }
            if cleaned.count == length {
                handleSubmittedCode(cleaned)
            }
        case .continueTapped:
            guard state.canContinue else { return }
            if state.phase == .newPhone {
                handleSubmittedPhone(state.e164PhoneNumber)
            } else {
                handleSubmittedCode(state.bindings.code)
            }
        case .cancel:
            actionsSubject.send(.close)
        case .done:
            actionsSubject.send(.close)
        }
    }

    // MARK: - Flow control

    private var currentCodeLength: Int {
        state.phase == .pin
            ? ChangePhoneScreenViewState.pinLength
            : ChangePhoneScreenViewState.otpLength
    }

    private func handleSubmittedPhone(_ phone: String) {
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ChangePhoneScreenViewState.isValid(phone: trimmed) else {
            state.errorMessage = L10n.screenPhoneLoginInvalidNumber
            return
        }
        state.newPhoneE164 = trimmed
        state.bindings.code = ""
        state.errorMessage = nil
        state.phase = .pin
    }

    private func handleSubmittedCode(_ code: String) {
        switch state.phase {
        case .pin:
            // Capture the PIN and request an OTP to the new number before collecting it.
            state.enteredPin = code
            Task { await requestOtpForNewNumber() }
        case .otp:
            Task { await submitChange(code: code) }
        default:
            break
        }
    }

    private func normalizeInput() {
        let raw = state.bindings.localPhoneNumber
        let (country, localDigits) = Country.normalize(rawInput: raw, current: state.selectedCountry)
        if country != state.selectedCountry {
            state.selectedCountry = country
        }
        if localDigits != raw.filter(\.isNumber) {
            state.bindings.localPhoneNumber = localDigits
        }
    }

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

    // MARK: - Backend interactions

    /// After the PIN is captured, send a verification OTP to the new number, then collect it.
    private func requestOtpForNewNumber() async {
        guard let accessToken = clientProxy.accessToken else {
            state.errorMessage = L10n.errorUnknown
            return
        }
        state.phase = .submitting
        userIndicatorController.submitIndicator(UserIndicator(id: indicatorID,
                                                              type: .modal,
                                                              title: L10n.commonLoading,
                                                              persistent: true))
        defer { userIndicatorController.retractIndicatorWithId(indicatorID) }
        do {
            try await identityServiceClient.requestPhoneChangeOTP(accessToken: accessToken,
                                                                  newPhone: state.newPhoneE164,
                                                                  language: Locale.current.identifier)
            state.bindings.code = ""
            state.errorMessage = nil
            state.phase = .otp
        } catch IdentityServiceError.rateLimited {
            state.errorMessage = IdentityServiceError.rateLimited.errorDescription
            state.bindings.code = ""
            state.phase = .pin
        } catch let IdentityServiceError.server(status, message) where status == 400 {
            // Invalid / unsupported number for the configured SMS region.
            state.errorMessage = message ?? L10n.screenPhoneLoginInvalidNumber
            state.bindings.localPhoneNumber = ""
            state.phase = .newPhone
        } catch {
            MXLog.error("Failed to request OTP for the new number: \(error)")
            state.errorMessage = (error as? LocalizedError)?.errorDescription ?? L10n.errorUnknown
            state.bindings.code = ""
            state.phase = .pin
        }
    }

    /// Final step — verify the new-number OTP + the account PIN; backend re-binds the number.
    private func submitChange(code: String) async {
        guard let accessToken = clientProxy.accessToken else {
            state.errorMessage = L10n.errorUnknown
            return
        }
        state.phase = .submitting
        userIndicatorController.submitIndicator(UserIndicator(id: indicatorID,
                                                              type: .modal,
                                                              title: L10n.commonLoading,
                                                              persistent: true))
        defer { userIndicatorController.retractIndicatorWithId(indicatorID) }
        do {
            try await identityServiceClient.changePhoneNumber(accessToken: accessToken,
                                                              userId: clientProxy.userID,
                                                              newPhone: state.newPhoneE164,
                                                              code: code,
                                                              pin: state.enteredPin)
            state.errorMessage = nil
            state.phase = .done
            userIndicatorController.submitIndicator(UserIndicator(id: successIndicatorID,
                                                                  type: .toast(progress: .none),
                                                                  title: L10n.screenChangePhoneSuccess,
                                                                  iconName: "checkmark"))
        } catch IdentityServiceError.invalidOTP {
            state.errorMessage = L10n.screenChangePhoneOtpInvalid
            state.bindings.code = ""
            state.phase = .otp
        } catch IdentityServiceError.invalidPin {
            // The PIN was wrong — return to the PIN step; re-submitting it requests a fresh OTP.
            state.errorMessage = L10n.screenChangePhonePinIncorrect
            state.bindings.code = ""
            state.enteredPin = ""
            state.phase = .pin
        } catch IdentityServiceError.phoneAlreadyLinked {
            state.errorMessage = L10n.screenChangePhoneAlreadyLinked
            state.bindings.code = ""
            state.bindings.localPhoneNumber = ""
            state.phase = .newPhone
        } catch IdentityServiceError.rateLimited {
            state.errorMessage = IdentityServiceError.rateLimited.errorDescription
            state.bindings.code = ""
            state.phase = .otp
        } catch {
            MXLog.error("Failed to change phone number: \(error)")
            state.errorMessage = (error as? LocalizedError)?.errorDescription ?? L10n.errorUnknown
            state.bindings.code = ""
            state.phase = .otp
        }
    }
}
