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
                // The server would not mint the ceremony at all, so this flow's passkey leg is
                // closed and re-running it later would only repeat the refusal. Nothing has been
                // spent yet, so the next factor can be asked for straight away.
                state.passkeyRefusedByServer = true
                fallBackFromPasskey(error: error)
                return
            }
            userIndicatorController.retractIndicatorWithId(indicatorID)

            let assertion: PasskeyAssertion
            do {
                assertion = try await passkeyStepUpPresenter.assertion(for: options)
            } catch {
                // Device side: this never reached the server, the credential is untouched and the
                // reauth token is unspent, so the passkey stays available to a later attempt.
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

        // `/start` consumes the single-use reauth token as its first act, BEFORE it looks at the
        // step-up, so the token is spent whatever the rest of the call then answers. Drop it here,
        // in one place, rather than per outcome: anything that carried it into a retry would earn
        // `invalid_reauth_token` and report an expiry that never happened, and the factor the user
        // still had to spend would never get its turn.
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
                                                                             language: Locale.current.identifier)
            state.challengeID = challenge.challengeID
            state.errorMessage = nil
            state.phase = .otp
        } catch {
            await handleStartChangeFailure(error)
        }
    }

    /// Routes a refusal from `/account/phone/change/start`.
    ///
    /// Every outcome here arrives with the reauth token already spent, so there are only three
    /// honest answers: the operation is over (the hard block), the account has to wait, or the flow
    /// goes back to where a token is minted. Nothing returns to a factor prompt still holding the
    /// dead token, because that prompt cannot succeed and would blame the wrong thing when it fails.
    private func handleStartChangeFailure(_ error: Error) async {
        switch error as? IdentityServiceError {
        case .stepUpRequired:
            // The hard block, as the server states it. The operation ends: the reauth token is
            // gone, and nothing here retries with a weaker proof.
            block(reason: .noFactorRegistered)
        case .twoFactorCooldown(let retry):
            // The mid-flow re-check. The factor exists but is too new to be spent yet.
            showCooldown(seconds: retry ?? 0)
        case .phoneChangeCooldown(let retry):
            showCooldown(seconds: retry ?? 0)
        case .pinLocked(let retry):
            // Too many wrong PINs. A fresh code would only arrive at a PIN that is still locked,
            // so the flow stops here rather than texting the user something they cannot use.
            showCooldown(seconds: retry ?? 0)
        case .passkeyUserVerificationRequired, .passkeyStepUpUnavailable:
            await fallBackFromRefusedPasskey()
        case .invalidPin:
            // The server burns the token before it checks the PIN, so a typo costs the whole reauth
            // leg. Say that plainly instead of letting the next attempt fail as a stale token.
            await restartAtReauth(message: L10n.screenChangePhonePinIncorrect)
        case .invalidReauthToken:
            // Single use, five minutes. Restart where the token is minted, which is also where the
            // step-up is presented again.
            await restartAtReauth(message: IdentityServiceError.invalidReauthToken.errorDescription)
        case .phoneAlreadyLinked:
            // Keep the typed number so the user can see which one was rejected and tweak it, and
            // surface the reason on the way back, otherwise the restart reads as an unexplained loop.
            userIndicatorController.submitIndicator(UserIndicator(title: L10n.screenChangePhoneAlreadyLinked,
                                                                  iconName: "xmark"))
            await restartAtReauth(message: L10n.screenChangePhoneAlreadyLinked)
        case .server(let status, let message) where status == 400:
            // Invalid or unsupported number for the configured SMS region.
            state.bindings.localPhoneNumber = ""
            await restartAtReauth(message: message ?? L10n.screenPhoneLoginInvalidNumber)
        case .rateLimited:
            // Resending immediately is exactly what is being rate limited, so hand the flow back to
            // the user rather than spending another code on their behalf.
            abandonFlow(message: IdentityServiceError.rateLimited.errorDescription ?? L10n.errorUnknown)
        default:
            MXLog.error("Failed to start the phone-number change: \(error)")
            abandonFlow(message: (error as? LocalizedError)?.errorDescription ?? L10n.errorUnknown)
        }
    }

    /// The server refused the assertion this device produced. The credential is registered and the
    /// ceremony did run, so running it again would reach the identical refusal; remember that for
    /// the rest of this flow so the PIN actually gets its turn. The server is told nothing, and the
    /// PIN is only reachable because the account holds one.
    private func fallBackFromRefusedPasskey() async {
        MXLog.info("The passkey step-up was refused by the server; the rest of this flow uses the PIN")
        state.passkeyRefusedByServer = true
        guard state.stepUpFactors.contains(.pin) else {
            // Nothing underneath the passkey, so there is no weaker proof to offer and none is
            // invented here.
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

    /// Ends the attempt without spending another code. The token is gone, so the flow starts again
    /// from the top when the user chooses to.
    private func abandonFlow(message: String) {
        state.challengeID = ""
        state.errorMessage = nil
        state.phase = .intro
        userIndicatorController.submitIndicator(UserIndicator(title: message, iconName: "xmark"))
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

    /// Goes back to where the reauth token is minted and sends a fresh code, so the step-up is
    /// produced again against a token that can actually be spent.
    ///
    /// Every proof the previous attempt held is dropped. What deliberately survives is
    /// ``ChangePhoneScreenViewState/passkeyRefusedByServer``, which is not a proof but a record of
    /// an answer the server already gave: re-offering the refused ceremony here is what would strand
    /// the flow in a loop the PIN could never break out of.
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

    /// The assertion was not produced on this device, or the ceremony could not be started. Offer
    /// the next factor down, and tell the server nothing: it never learns that a passkey was
    /// unavailable, because that claim is free to make and could only ever ask for something weaker.
    ///
    /// The reauth token has not been spent on either of these paths, so the PIN can be asked for
    /// straight away. A refusal that comes back from `/start` is the other case and goes through
    /// ``fallBackFromRefusedPasskey()``, which has to mint a fresh token first.
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
