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
    /// Runs the passkey assertion. `nil` means this context cannot present one at all, which reads
    /// exactly like a device that cannot produce an assertion: the PIN is offered instead. It is
    /// never turned into a claim to the server.
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
            state.reauthToken = ""
            state.challengeID = ""
            state.stepUpFactors = []
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
            if state.phase == .newPhone {
                handleSubmittedPhone(state.e164PhoneNumber)
            } else {
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

    private func handleSubmittedCode(_ code: String) {
        switch state.phase {
        case .reauth:
            Task { await verifyReauthCode(code) }
        case .pin:
            // The PIN is the step-up factor, and it travels with the start request rather than
            // being validated on its own first: one call, one factor, checked by the side that
            // enforces it.
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

    /// Reads the account's factor report (`GET /security/pin/status`) and routes on it.
    ///
    /// This runs before anything is sent anywhere, which is the point of doing it first: an account
    /// that could never finish the flow is stopped here rather than after an SMS. What it decides
    /// is which factor to offer, never whether the operation is allowed; the server settles that
    /// when the step-up is presented, and a refusal there is still honoured below.
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
            // The hold this field reports is the PIN's. An account whose only offerable factor is
            // the PIN would walk the whole flow into a refusal, so it is shown the wait now. An
            // account that can offer a passkey is not held by a PIN it is not going to spend, and
            // if the passkey turns out to be too new the server says so mid-flow and that refusal
            // lands in the same interstitial.
            if state.stepUpFactors == [.pin], let hold = status.pinStepUpHoldRemainingSeconds, hold > 0 {
                state.cooldownRemainingSeconds = hold
                state.phase = .cooldown
                return
            }
            await startReauth(accessToken: accessToken)
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

    /// Sends the reauth OTP to the CURRENT number. Nothing reaches the new number here, and nothing
    /// reaches this number either until the account is known to hold a factor that can finish.
    private func startReauth(accessToken: String) async {
        do {
            try await identityServiceClient.startAccountReauth(accessToken: accessToken,
                                                               language: Locale.current.identifier)
            state.bindings.code = ""
            state.errorMessage = nil
            state.phase = .reauth
        } catch {
            MXLog.error("Failed to start account reauth for change-phone: \(error)")
            userIndicatorController.submitIndicator(UserIndicator(title: (error as? LocalizedError)?.errorDescription ?? L10n.errorUnknown,
                                                                  iconName: "xmark"))
            state.phase = .intro
        }
    }

    /// Exchanges the reauth code for a token scoped to this one operation.
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
                                                                                    code: code,
                                                                                    operation: .phoneChange)
            state.bindings.code = ""
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
        } catch {
            MXLog.error("Failed to verify the reauth code: \(error)")
            state.errorMessage = (error as? LocalizedError)?.errorDescription ?? L10n.errorUnknown
            state.bindings.code = ""
            state.phase = .reauth
        }
    }

    /// Produces the step-up factor, strongest first, and starts the change with it.
    ///
    /// The order is the server's published one. A passkey is attempted only when the account holds
    /// one and this device can run the ceremony; whatever happens inside that ceremony stays on the
    /// device and turns into "ask for the next factor", never into a message saying a factor was
    /// declined.
    private func stepUp() async {
        if state.stepUpFactors.first == .passkey, let passkeyStepUpPresenter {
            guard let accessToken = clientProxy.accessToken else {
                state.errorMessage = L10n.errorUnknown
                return
            }
            state.phase = .submitting
            userIndicatorController.submitIndicator(UserIndicator(id: indicatorID,
                                                                  type: .modal,
                                                                  title: L10n.commonLoading,
                                                                  persistent: true))
            let assertion: PasskeyAssertion
            let options: PasskeyStepUpOptions
            do {
                options = try await identityServiceClient.startPasskeyStepUp(accessToken: accessToken)
                userIndicatorController.retractIndicatorWithId(indicatorID)
                assertion = try await passkeyStepUpPresenter.assertion(for: options)
            } catch {
                userIndicatorController.retractIndicatorWithId(indicatorID)
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

        // Either the account holds only a passkey and this build cannot present one, or the report
        // named nothing this client can produce. Both are the same answer to the user, and neither
        // is a reason to proceed on the reauth token alone.
        block(reason: state.stepUpFactors.contains(.passkey) ? .passkeyUnusableHere : .noFactorRegistered)
    }

    /// Spends the reauth token together with the step-up factor. The SMS to the new number is sent
    /// by the server inside this call, and only after the step-up has been accepted.
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
        do {
            let challenge = try await identityServiceClient.startPhoneChange(accessToken: accessToken,
                                                                             reauthToken: state.reauthToken,
                                                                             newPhone: state.newPhoneE164,
                                                                             pin: pin,
                                                                             passkeyStepUpID: passkey?.stepUpID,
                                                                             passkeyAssertion: passkey?.assertion,
                                                                             language: Locale.current.identifier)
            // The token is single use and has just been spent.
            state.reauthToken = ""
            state.challengeID = challenge.challengeID
            state.bindings.code = ""
            state.errorMessage = nil
            state.phase = .otp
        } catch IdentityServiceError.stepUpRequired {
            // The hard block, as the server states it. The operation ends: the reauth token is
            // gone, and nothing here retries with a weaker proof.
            state.reauthToken = ""
            state.bindings.code = ""
            block(reason: .noFactorRegistered)
        } catch let IdentityServiceError.twoFactorCooldown(retry) {
            // The mid-flow re-check. The factor exists but is too new to be spent yet.
            state.reauthToken = ""
            state.bindings.code = ""
            state.errorMessage = nil
            state.cooldownRemainingSeconds = retry ?? 0
            state.phase = .cooldown
        } catch let IdentityServiceError.phoneChangeCooldown(retry) {
            state.reauthToken = ""
            state.bindings.code = ""
            state.errorMessage = nil
            state.cooldownRemainingSeconds = retry ?? 0
            state.phase = .cooldown
        } catch IdentityServiceError.passkeyUserVerificationRequired {
            fallBackFromPasskey(error: IdentityServiceError.passkeyUserVerificationRequired)
        } catch IdentityServiceError.passkeyStepUpUnavailable {
            fallBackFromPasskey(error: IdentityServiceError.passkeyStepUpUnavailable)
        } catch IdentityServiceError.invalidPin {
            state.errorMessage = L10n.screenChangePhonePinIncorrect
            state.bindings.code = ""
            state.phase = .pin
        } catch let IdentityServiceError.pinLocked(retry) {
            state.errorMessage = IdentityServiceError.pinLocked(retryAfterSeconds: retry).errorDescription
            state.bindings.code = ""
            state.phase = .pin
        } catch IdentityServiceError.invalidReauthToken {
            // Single use, five minutes. Restart where the token is minted, which is also where the
            // step-up is presented again; nothing is carried over.
            await restartAtReauth(message: IdentityServiceError.invalidReauthToken.errorDescription)
        } catch IdentityServiceError.phoneAlreadyLinked {
            // Keep the typed number so the user can see which one was rejected and tweak it, and
            // surface the reason as a toast, otherwise the bounce back reads as an unexplained loop.
            state.errorMessage = L10n.screenChangePhoneAlreadyLinked
            state.bindings.code = ""
            state.phase = .newPhone
            userIndicatorController.submitIndicator(UserIndicator(title: L10n.screenChangePhoneAlreadyLinked,
                                                                  iconName: "xmark"))
        } catch IdentityServiceError.rateLimited {
            state.errorMessage = IdentityServiceError.rateLimited.errorDescription
            state.bindings.code = ""
            state.phase = state.stepUpFactors.contains(.pin) ? .pin : .newPhone
        } catch let IdentityServiceError.server(status, message) where status == 400 {
            // Invalid or unsupported number for the configured SMS region.
            state.errorMessage = message ?? L10n.screenPhoneLoginInvalidNumber
            state.bindings.localPhoneNumber = ""
            state.phase = .newPhone
        } catch {
            MXLog.error("Failed to start the phone-number change: \(error)")
            state.errorMessage = (error as? LocalizedError)?.errorDescription ?? L10n.errorUnknown
            state.bindings.code = ""
            state.phase = .newPhone
        }
    }

    /// Redeems the challenge with the code that arrived at the new number.
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
            // The challenge is gone, and it can only be reissued by proving everything again.
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

    /// Goes back to where the reauth token is minted and sends a fresh code. Everything the
    /// previous attempt held is dropped, so the step-up is produced again too.
    private func restartAtReauth(message: String?) async {
        guard let accessToken = clientProxy.accessToken else {
            state.errorMessage = L10n.errorUnknown
            state.phase = .intro
            return
        }
        state.reauthToken = ""
        state.challengeID = ""
        state.bindings.code = ""
        await startReauth(accessToken: accessToken)
        if state.phase == .reauth {
            state.errorMessage = message
        }
    }

    /// This device could not produce the assertion. Offer the next factor down, and tell the server
    /// nothing: it never learns that a passkey was unavailable, because that claim is free to make
    /// and could only ever ask for something weaker.
    private func fallBackFromPasskey(error: Error) {
        MXLog.info("Passkey step-up was not produced on this device; offering the next factor")
        let cancelled: Bool
        if let stepUpError = error as? PasskeyStepUpError, case .cancelled = stepUpError {
            cancelled = true
        } else {
            cancelled = false
        }
        guard state.stepUpFactors.contains(.pin) else {
            // Nothing underneath the passkey. A deliberate dismissal just returns to the number so
            // it can be tried again; anything else is explained on the block screen.
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
