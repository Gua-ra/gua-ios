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
    /// `nil` means this context cannot present a passkey, which is treated like a device that cannot
    /// produce an assertion: the PIN is offered instead.
    private let passkeyStepUpPresenter: PasskeyStepUpPresenting?

    private let actionsSubject: PassthroughSubject<ChangePhoneScreenViewModelAction, Never> = .init()
    var actionsPublisher: AnyPublisher<ChangePhoneScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    private let indicatorID = "ChangePhoneScreen-Submit"
    private let successIndicatorID = "ChangePhoneScreen-Success"

    init(clientProxy: ClientProxyProtocol,
         identityServiceClient: IdentityServiceClientProtocol,
         userIndicatorController: UserIndicatorControllerProtocol,
         passkeyStepUpPresenter: PasskeyStepUpPresenting? = nil) {
        self.clientProxy = clientProxy
        self.identityServiceClient = identityServiceClient
        self.userIndicatorController = userIndicatorController
        self.passkeyStepUpPresenter = passkeyStepUpPresenter

        super.init(initialViewState: ChangePhoneScreenViewState())
    }

    override func process(viewAction: ChangePhoneScreenViewAction) {
        switch viewAction {
        case .start:
            state.selectedCountry = .deviceDefault
            state.bindings.localPhoneNumber = ""
            state.currentPhoneE164 = ""
            state.reauthToken = ""
            state.challengeID = ""
            state.stepUpFactors = []
            state.passkeyRefusedByServer = false
            state.bindings.code = ""
            state.errorMessage = nil
            Task { await beginFlow() }
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
            switch state.phase {
            case .currentPhone:
                handleSubmittedCurrentPhone(state.e164PhoneNumber)
            case .newPhone:
                handleSubmittedPhone(state.e164PhoneNumber)
            default:
                handleSubmittedCode(state.bindings.code)
            }
        case .cancel:
            actionsSubject.send(.close)
        case .done:
            actionsSubject.send(.close)
        case .setUpStepUpFactor(let factor):
            actionsSubject.send(.setUpStepUpFactor(factor))
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
        state.errorMessage = nil
        Task { await stepUp() }
    }

    private func handleSubmittedCurrentPhone(_ phone: String) {
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ChangePhoneScreenViewState.isValid(phone: trimmed) else {
            state.errorMessage = L10n.screenPhoneLoginInvalidNumber
            return
        }
        state.currentPhoneE164 = trimmed
        state.errorMessage = nil
        Task { await sendReauthCode() }
    }

    private func handleSubmittedCode(_ code: String) {
        switch state.phase {
        case .reauth:
            Task { await verifyReauthCode(code) }
        case .pin:
            Task { await startChange(pin: code, passkey: nil) }
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

    /// Reads the account's factor report (`GET /security/pin/status`) and routes on it. Runs before
    /// anything is sent, so an account that cannot finish is never texted. It decides which factor to
    /// offer, never whether the operation is allowed: the server settles that at the step-up.
    private func beginFlow() async {
        guard let accessToken = clientProxy.accessToken else {
            state.errorMessage = L10n.errorUnknown
            state.phase = .intro
            return
        }
        state.phase = .submitting
        userIndicatorController.submitIndicator(UserIndicator(id: indicatorID,
                                                              type: .modal,
                                                              title: L10n.commonLoading,
                                                              persistent: true))
        defer { userIndicatorController.retractIndicatorWithId(indicatorID) }
        do {
            let status = try await identityServiceClient.securityStatus(accessToken: accessToken)
            state.stepUpFactors = status.offerablePhoneChangeStepUpFactors
            guard !state.stepUpFactors.isEmpty else {
                block(reason: .noFactorRegistered)
                return
            }
            // The reported hold applies to the PIN only, so an account that can offer a passkey is not held.
            if state.stepUpFactors == [.pin], let hold = status.pinStepUpHoldRemainingSeconds, hold > 0 {
                state.cooldownRemainingSeconds = hold
                state.phase = .cooldown
                return
            }
            askForCurrentPhone()
        } catch IdentityServiceError.stepUpRequired {
            block(reason: .noFactorRegistered)
        } catch let IdentityServiceError.twoFactorCooldown(retry) {
            state.cooldownRemainingSeconds = retry ?? 0
            state.phase = .cooldown
        } catch {
            MXLog.error("Failed to fetch the account's factor status for change-phone: \(error)")
            userIndicatorController.submitIndicator(UserIndicator(title: (error as? LocalizedError)?.errorDescription ?? L10n.errorUnknown,
                                                                  iconName: "xmark"))
            state.phase = .intro
        }
    }

    /// Refusals shown on the number step rather than the code step.
    private static func belongsOnTheNumberStep(_ error: IdentityServiceError) -> Bool {
        switch error {
        case .reauthPhoneMismatch, .invalidPhoneNumber, .rateLimited: true
        default: false
        }
    }

    /// Excludes `rateLimited`: the server uses it for the ordinary OTP quotas too.
    private static func isAboutTheSubmittedNumber(_ error: IdentityServiceError) -> Bool {
        switch error {
        case .reauthPhoneMismatch, .invalidPhoneNumber: true
        default: false
        }
    }

    /// Empties the field by default. `keepingConfirmedNumber` puts back a number the server already
    /// accepted, because retyping it proves nothing.
    private func askForCurrentPhone(message: String? = nil, keepingConfirmedNumber: Bool = false) {
        state.bindings.code = ""
        if keepingConfirmedNumber, !state.currentPhoneE164.isEmpty {
            let (country, localDigits) = Country.normalize(rawInput: state.currentPhoneE164, current: state.selectedCountry)
            state.selectedCountry = country
            state.bindings.localPhoneNumber = country.formatNational(digits: localDigits)
        } else {
            state.bindings.localPhoneNumber = ""
        }
        state.errorMessage = message
        state.phase = .currentPhone
    }

    private func sendReauthCode() async {
        guard let accessToken = clientProxy.accessToken else {
            state.errorMessage = L10n.errorUnknown
            state.phase = .intro
            return
        }
        let isConfirmingNumber = state.phase == .currentPhone
        state.phase = .submitting
        userIndicatorController.submitIndicator(UserIndicator(id: indicatorID,
                                                              type: .modal,
                                                              title: L10n.commonLoading,
                                                              persistent: true))
        defer { userIndicatorController.retractIndicatorWithId(indicatorID) }
        do {
            try await identityServiceClient.startAccountReauth(accessToken: accessToken,
                                                               phone: state.currentPhoneE164,
                                                               language: Locale.guaLanguageTag())
            state.bindings.code = ""
            state.errorMessage = nil
            state.phase = .reauth
        } catch let error as IdentityServiceError where Self.belongsOnTheNumberStep(error) {
            if isConfirmingNumber {
                state.errorMessage = error.errorDescription
                state.phase = .currentPhone
            } else {
                askForCurrentPhone(message: error.errorDescription,
                                   keepingConfirmedNumber: !Self.isAboutTheSubmittedNumber(error))
            }
        } catch {
            MXLog.error("Failed to start account reauth for change-phone: \(error)")
            userIndicatorController.submitIndicator(UserIndicator(title: (error as? LocalizedError)?.errorDescription ?? L10n.errorUnknown,
                                                                  iconName: "xmark"))
            state.phase = .intro
        }
    }

    private func verifyReauthCode(_ code: String) async {
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
            state.reauthToken = try await identityServiceClient.verifyAccountReauth(accessToken: accessToken,
                                                                                    phone: state.currentPhoneE164,
                                                                                    code: code,
                                                                                    operation: .phoneChange)
            state.bindings.code = ""
            state.bindings.localPhoneNumber = ""
            state.errorMessage = nil
            state.phase = .newPhone
        } catch IdentityServiceError.invalidOTP {
            state.errorMessage = L10n.screenOtpInvalidCode
            state.bindings.code = ""
            state.phase = .reauth
        } catch IdentityServiceError.rateLimited {
            state.errorMessage = IdentityServiceError.rateLimited.errorDescription
            state.bindings.code = ""
            state.phase = .reauth
        } catch let error as IdentityServiceError where Self.isAboutTheSubmittedNumber(error) {
            askForCurrentPhone(message: error.errorDescription)
        } catch {
            MXLog.error("Failed to verify the reauth code: \(error)")
            state.errorMessage = (error as? LocalizedError)?.errorDescription ?? L10n.errorUnknown
            state.bindings.code = ""
            state.phase = .reauth
        }
    }

    /// Produces the step-up factor, strongest first, and starts the change with it. A passkey failure
    /// on the device becomes "ask for the next factor" and is never reported to the server.
    private func stepUp() async {
        if state.stepUpFactors.first == .passkey, !state.passkeyRefusedByServer, let passkeyStepUpPresenter {
            guard let accessToken = clientProxy.accessToken else {
                state.errorMessage = L10n.errorUnknown
                return
            }
            state.phase = .submitting
            userIndicatorController.submitIndicator(UserIndicator(id: indicatorID,
                                                                  type: .modal,
                                                                  title: L10n.commonLoading,
                                                                  persistent: true))
            let options: PasskeyStepUpOptions
            do {
                options = try await identityServiceClient.startPasskeyStepUp(accessToken: accessToken)
            } catch {
                userIndicatorController.retractIndicatorWithId(indicatorID)
                state.passkeyRefusedByServer = true
                fallBackFromPasskey(error: error)
                return
            }
            userIndicatorController.retractIndicatorWithId(indicatorID)

            let assertion: PasskeyAssertion
            do {
                assertion = try await passkeyStepUpPresenter.assertion(for: options)
            } catch {
                fallBackFromPasskey(error: error)
                return
            }
            await startChange(pin: nil, passkey: (options.stepUpID, assertion))
            return
        }

        if state.stepUpFactors.contains(.pin) {
            state.bindings.code = ""
            state.errorMessage = nil
            state.phase = .pin
            return
        }

        block(reason: state.stepUpFactors.contains(.passkey) ? .passkeyUnusableHere : .noFactorRegistered)
    }

    /// Spends the reauth token together with the step-up factor. The server sends the SMS to the new
    /// number inside this call, and only after it accepts the step-up.
    private func startChange(pin: String?, passkey: (stepUpID: String, assertion: PasskeyAssertion)?) async {
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

        // `/start` consumes the reauth token before it checks the step-up, so the token is spent whatever the outcome.
        let spentReauthToken = state.reauthToken
        state.reauthToken = ""
        state.bindings.code = ""

        do {
            let challenge = try await identityServiceClient.startPhoneChange(accessToken: accessToken,
                                                                             reauthToken: spentReauthToken,
                                                                             newPhone: state.newPhoneE164,
                                                                             pin: pin,
                                                                             passkeyStepUpID: passkey?.stepUpID,
                                                                             passkeyAssertion: passkey?.assertion,
                                                                             language: Locale.guaLanguageTag())
            state.challengeID = challenge.challengeID
            state.errorMessage = nil
            state.phase = .otp
        } catch {
            await handleStartChangeFailure(error)
        }
    }

    /// Routes a refusal from `/account/phone/change/start`. The reauth token is already spent, so the
    /// flow ends (hard block), waits (cooldown) or returns to where a token is issued.
    private func handleStartChangeFailure(_ error: Error) async {
        switch error as? IdentityServiceError {
        case .stepUpRequired:
            block(reason: .noFactorRegistered)
        case .twoFactorCooldown(let retry):
            showCooldown(seconds: retry ?? 0)
        case .phoneChangeCooldown(let retry):
            showCooldown(seconds: retry ?? 0)
        case .pinLocked(let retry):
            showCooldown(seconds: retry ?? 0)
        case .passkeyUserVerificationRequired, .passkeyStepUpUnavailable:
            await fallBackFromRefusedPasskey()
        case .invalidPin:
            // The server burns the token before it checks the PIN, so a wrong PIN restarts at reauth.
            await restartAtReauth(message: L10n.screenChangePhonePinIncorrect)
        case .invalidReauthToken:
            await restartAtReauth(message: IdentityServiceError.invalidReauthToken.errorDescription)
        case .phoneAlreadyLinked:
            userIndicatorController.submitIndicator(UserIndicator(title: L10n.screenChangePhoneAlreadyLinked,
                                                                  iconName: "xmark"))
            await restartAtReauth(message: L10n.screenChangePhoneAlreadyLinked)
        case .server(let status, let message) where status == 400:
            // Invalid or unsupported number for the configured SMS region.
            state.bindings.localPhoneNumber = ""
            await restartAtReauth(message: message ?? L10n.screenPhoneLoginInvalidNumber)
        case .rateLimited:
            // Restarting would send another code while rate limited.
            abandonFlow(message: IdentityServiceError.rateLimited.errorDescription ?? L10n.errorUnknown)
        default:
            MXLog.error("Failed to start the phone-number change: \(error)")
            abandonFlow(message: (error as? LocalizedError)?.errorDescription ?? L10n.errorUnknown)
        }
    }

    /// The server refused the assertion, so running the ceremony again would fail the same way. The
    /// rest of the flow uses the PIN, if the account holds one.
    private func fallBackFromRefusedPasskey() async {
        MXLog.info("The passkey step-up was refused by the server; the rest of this flow uses the PIN")
        state.passkeyRefusedByServer = true
        guard state.stepUpFactors.contains(.pin) else {
            block(reason: .passkeyUnusableHere)
            return
        }
        await restartAtReauth(message: L10n.screenChangePhonePasskeyRefusedRestart)
    }

    private func showCooldown(seconds: Int) {
        state.errorMessage = nil
        state.cooldownRemainingSeconds = seconds
        state.phase = .cooldown
    }

    /// Ends the attempt without spending another code.
    private func abandonFlow(message: String) {
        state.challengeID = ""
        state.errorMessage = nil
        state.phase = .intro
        userIndicatorController.submitIndicator(UserIndicator(title: message, iconName: "xmark"))
    }

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
            try await identityServiceClient.completePhoneChange(accessToken: accessToken,
                                                                challengeId: state.challengeID,
                                                                code: code)
            state.challengeID = ""
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
        } catch IdentityServiceError.phoneChangeChallengeInvalid {
            await restartAtReauth(message: IdentityServiceError.phoneChangeChallengeInvalid.errorDescription)
        } catch IdentityServiceError.phoneAlreadyLinked {
            state.errorMessage = L10n.screenChangePhoneAlreadyLinked
            state.bindings.code = ""
            state.phase = .newPhone
            userIndicatorController.submitIndicator(UserIndicator(title: L10n.screenChangePhoneAlreadyLinked,
                                                                  iconName: "xmark"))
        } catch IdentityServiceError.rateLimited {
            state.errorMessage = IdentityServiceError.rateLimited.errorDescription
            state.bindings.code = ""
            state.phase = .otp
        } catch {
            MXLog.error("Failed to complete the phone-number change: \(error)")
            state.errorMessage = (error as? LocalizedError)?.errorDescription ?? L10n.errorUnknown
            state.bindings.code = ""
            state.phase = .otp
        }
    }

    /// Goes back to where the reauth token is issued and sends a fresh code. `passkeyRefusedByServer`
    /// survives the restart, otherwise the refused passkey is offered again and the PIN is never reached.
    private func restartAtReauth(message: String?) async {
        state.reauthToken = ""
        state.challengeID = ""
        state.bindings.code = ""
        guard !state.currentPhoneE164.isEmpty else {
            askForCurrentPhone(message: message)
            return
        }
        await sendReauthCode()
        if state.phase == .reauth {
            state.errorMessage = message
        }
    }

    /// The assertion was not produced on this device. Offers the next factor and tells the server
    /// nothing. The reauth token is unspent here, so the PIN can be asked for straight away.
    private func fallBackFromPasskey(error: Error) {
        MXLog.info("Passkey step-up was not produced on this device; offering the next factor")
        let cancelled: Bool
        if let stepUpError = error as? PasskeyStepUpError, case .cancelled = stepUpError {
            cancelled = true
        } else {
            cancelled = false
        }
        guard state.stepUpFactors.contains(.pin) else {
            if cancelled {
                state.phase = .newPhone
            } else {
                block(reason: .passkeyUnusableHere)
            }
            return
        }
        state.bindings.code = ""
        state.errorMessage = cancelled ? nil : L10n.screenChangePhonePasskeyFallback
        state.phase = .pin
    }

    private func block(reason: ChangePhoneStepUpBlockReason) {
        state.stepUpBlockReason = reason
        state.errorMessage = nil
        state.phase = .stepUpRequired
    }
}
