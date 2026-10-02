//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

typealias TwoStepVerificationScreenViewModelType = StateStoreViewModelV2<TwoStepVerificationScreenViewState, TwoStepVerificationScreenViewAction>

class TwoStepVerificationScreenViewModel: TwoStepVerificationScreenViewModelType, TwoStepVerificationScreenViewModelProtocol {
    private let clientProxy: ClientProxyProtocol
    private let identityServiceClient: IdentityServiceClientProtocol
    private let userIndicatorController: UserIndicatorControllerProtocol
    /// Runs the passkey assertion that authorizes a PIN change. `nil` means this context cannot
    /// present one, and the current PIN is asked for instead.
    private let passkeyStepUpPresenter: PasskeyStepUpPresenting?
    /// Changes on cancel, so work still running for a cancelled change can tell its result is unwanted.
    private var flowID = UUID()

    private let actionsSubject: PassthroughSubject<TwoStepVerificationScreenViewModelAction, Never> = .init()
    var actionsPublisher: AnyPublisher<TwoStepVerificationScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    /// A factor the caller asked this screen to set up on arrival, from the change-phone block screen.
    private let initialSetup: AuthFactor?
    /// One shot: a later reload must not reopen a setup the user has already dealt with.
    private var appliedInitialSetup = false

    private let indicatorID = "TwoStepVerificationScreen-Submit"
    private let successIndicatorID = "TwoStepVerificationScreen-Success"

    private var userHasPin: Bool {
        state.factors?.hasPin ?? false
    }

    init(clientProxy: ClientProxyProtocol,
         identityServiceClient: IdentityServiceClientProtocol,
         userIndicatorController: UserIndicatorControllerProtocol,
         passkeyStepUpPresenter: PasskeyStepUpPresenting? = nil,
         initialSetup: AuthFactor? = nil) {
        self.clientProxy = clientProxy
        self.identityServiceClient = identityServiceClient
        self.userIndicatorController = userIndicatorController
        self.passkeyStepUpPresenter = passkeyStepUpPresenter
        self.initialSetup = initialSetup

        super.init(initialViewState: TwoStepVerificationScreenViewState())

        Task { await loadStatus() }
    }

    override func process(viewAction: TwoStepVerificationScreenViewAction) {
        switch viewAction {
        case .startSetup:
            actionsSubject.send(.setUpPin)
        case .startChange:
            resetFlowState()
            state.selectedCountry = .deviceDefault
            state.phase = .enteringPhone
        case .phoneChanged:
            normalizeInput()
            autoDetectCountry()
            reformatNumber()
            if state.errorMessage != nil { state.errorMessage = nil }
        case .countrySelected(let country):
            state.selectedCountry = country
            state.bindings.isCountryPickerPresented = false
            reformatNumber()
        case .pinChanged:
            let length = state.phase == .enteringOtp
                ? TwoStepVerificationScreenViewState.otpLength
                : TwoStepVerificationScreenViewState.pinLength
            let cleaned = String(state.bindings.pin.filter(\.isNumber).prefix(length))
            if cleaned != state.bindings.pin {
                state.bindings.pin = cleaned
            }
            if state.errorMessage != nil { state.errorMessage = nil }
            if cleaned.count == length {
                handleSubmittedCode(cleaned)
            }
        case .continueTapped:
            guard state.canContinue else { return }
            if state.phase == .enteringPhone {
                handleSubmittedPhone(state.e164PhoneNumber)
            } else {
                handleSubmittedCode(state.bindings.pin)
            }
        case .retryStatus:
            Task { await loadStatus() }
        case .cancelEntry:
            resetFlowState()
            state.phase = .overview
        case .setUpPasskey:
            actionsSubject.send(.setUpPasskey)
        }
    }

    // MARK: - Flow control

    private func resetFlowState() {
        flowID = UUID()
        state.errorMessage = nil
        state.currentPin = ""
        state.stagedNewPin = ""
        state.challengeId = nil
        state.otpCode = ""
        state.phone = ""
        state.bindings.pin = ""
        state.bindings.localPhoneNumber = ""
        state.bindings.isCountryPickerPresented = false
    }

    /// Strips an international prefix that autofill pastes into the local-number field, switching the
    /// country when needed. Mirrors `PhoneEntryScreenViewModel`.
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

    private func handleSubmittedPhone(_ phone: String) {
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TwoStepVerificationScreenViewState.isValid(phone: trimmed) else {
            state.errorMessage = L10n.screenPhoneLoginInvalidNumber
            return
        }
        state.phone = trimmed
        state.bindings.pin = ""
        if state.factors?.passkeyRegistered == true, let passkeyStepUpPresenter {
            Task { await authorizeWithPasskeyAndRequestOtp(presenter: passkeyStepUpPresenter) }
            return
        }
        state.phase = .enteringCurrent
    }

    private func handleSubmittedCode(_ code: String) {
        switch state.phase {
        case .enteringCurrent:
            Task { await verifyCurrentPinAndRequestOtp(code) }
        case .enteringOtp:
            state.otpCode = code
            state.bindings.pin = ""
            state.phase = .enteringNew
        case .enteringNew:
            if isWeak(pin: code) {
                state.errorMessage = L10n.screenPinSetupWeakError
                state.bindings.pin = ""
                return
            }
            if userHasPin, !state.currentPin.isEmpty, code == state.currentPin {
                state.errorMessage = L10n.screenTwoStepVerificationSameAsCurrent
                state.bindings.pin = ""
                return
            }
            state.stagedNewPin = code
            state.bindings.pin = ""
            state.phase = .confirmingNew
        case .confirmingNew:
            guard code == state.stagedNewPin else {
                state.errorMessage = L10n.screenPinSetupMismatchError
                state.bindings.pin = ""
                state.stagedNewPin = ""
                state.phase = .enteringNew
                return
            }
            Task { await submitNewPin(code) }
        default:
            break
        }
    }

    // MARK: - Backend interactions

    private func loadStatus() async {
        guard let accessToken = clientProxy.accessToken else {
            state.factors = nil
            state.phase = .overview
            state.errorMessage = L10n.errorUnknown
            return
        }
        state.phase = .loading
        do {
            state.factors = try await identityServiceClient.securityStatus(accessToken: accessToken)
            state.errorMessage = nil
            state.phase = .overview
            applyInitialSetup()
        } catch {
            // A report that could not be read leaves `factors` nil. It must not collapse into "no PIN".
            MXLog.error("Failed to fetch the account's factor status: \(error)")
            state.factors = nil
            state.phase = .overview
            state.errorMessage = (error as? LocalizedError)?.errorDescription ?? L10n.errorUnknown
        }
    }

    /// Opens the setup the caller asked for, once the report says it is still needed. A factor the
    /// account already holds opens nothing.
    private func applyInitialSetup() {
        guard !appliedInitialSetup else { return }
        appliedInitialSetup = true
        switch initialSetup {
        case .passkey where !(state.factors?.passkeyRegistered ?? true):
            actionsSubject.send(.setUpPasskey)
        case .pin where !userHasPin:
            actionsSubject.send(.setUpPin)
        default:
            break
        }
    }

    /// Authorizes the change with a passkey assertion and goes straight to the texted code; the
    /// current PIN is not asked for. A refused passkey falls back to the current-PIN step, and the
    /// server is not told why. Other failures (offline, a server error) are shown as they are.
    private func authorizeWithPasskeyAndRequestOtp(presenter: PasskeyStepUpPresenting) async {
        guard let accessToken = clientProxy.accessToken else {
            state.errorMessage = L10n.errorUnknown
            return
        }
        let phone = state.phone
        let flow = flowID
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
            guard flow == flowID else { return }
            handlePasskeyFailure(error)
            return
        }
        userIndicatorController.retractIndicatorWithId(indicatorID)
        guard flow == flowID else { return }

        let assertion: PasskeyAssertion
        do {
            assertion = try await presenter.assertion(for: options)
        } catch {
            guard flow == flowID else { return }
            if let stepUpError = error as? PasskeyStepUpError, case .cancelled = stepUpError {
                fallBackToCurrentPin(message: nil)
            } else {
                fallBackToCurrentPin(message: L10n.screenChangePhonePasskeyFallback)
            }
            return
        }
        guard flow == flowID else { return }

        state.phase = .submitting
        userIndicatorController.submitIndicator(UserIndicator(id: indicatorID,
                                                              type: .modal,
                                                              title: L10n.commonLoading,
                                                              persistent: true))
        defer { userIndicatorController.retractIndicatorWithId(indicatorID) }
        do {
            let challengeId = try await identityServiceClient.startPinChange(accessToken: accessToken,
                                                                             phone: phone,
                                                                             currentPin: nil,
                                                                             passkeyStepUpID: options.stepUpID,
                                                                             passkeyAssertion: assertion)
            guard flow == flowID else { return }
            state.challengeId = challengeId
            state.bindings.pin = ""
            state.errorMessage = nil
            state.phase = .enteringOtp
        } catch {
            guard flow == flowID else { return }
            handlePasskeyFailure(error)
        }
    }

    private func handlePasskeyFailure(_ error: Error) {
        switch error {
        case IdentityServiceError.pinLocked:
            state.errorMessage = L10n.screenTwoStepVerificationLocked
            state.phase = .overview
        case let IdentityServiceError.pinChangeCooldown(retry):
            state.errorMessage = IdentityServiceError.pinChangeCooldown(retryAfterSeconds: retry).errorDescription
            state.phase = .overview
        case IdentityServiceError.invalidPin, // another account's passkey arrives as invalid_pin
             IdentityServiceError.twoFactorCooldown, // registered too recently to authorize this
             IdentityServiceError.passkeyUserVerificationRequired,
             IdentityServiceError.passkeyStepUpUnavailable:
            MXLog.info("The server refused the passkey for this PIN change; asking for the current PIN: \(error)")
            fallBackToCurrentPin(message: L10n.screenChangePhonePasskeyFallback)
        case let IdentityServiceError.server(status, _) where (400..<500).contains(status):
            MXLog.info("The server refused the passkey for this PIN change; asking for the current PIN: \(error)")
            fallBackToCurrentPin(message: L10n.screenChangePhonePasskeyFallback)
        default:
            // Rate limited, offline or a server error: nothing was decided about the passkey, so the
            // number step can try again.
            MXLog.error("Failed to start a passkey-authorized PIN change: \(error)")
            state.errorMessage = (error as? LocalizedError)?.errorDescription ?? L10n.errorUnknown
            state.phase = .enteringPhone
        }
    }

    private func fallBackToCurrentPin(message: String?) {
        state.bindings.pin = ""
        state.errorMessage = message
        state.phase = .enteringCurrent
    }

    private func verifyCurrentPinAndRequestOtp(_ currentPin: String) async {
        guard let accessToken = clientProxy.accessToken else {
            state.errorMessage = L10n.errorUnknown
            return
        }
        let phone = state.phone
        guard !phone.isEmpty else {
            state.errorMessage = L10n.errorUnknown
            state.phase = .enteringPhone
            return
        }
        let previousPhase = state.phase
        state.phase = .submitting
        userIndicatorController.submitIndicator(UserIndicator(id: indicatorID,
                                                              type: .modal,
                                                              title: L10n.commonLoading,
                                                              persistent: true))
        defer { userIndicatorController.retractIndicatorWithId(indicatorID) }
        do {
            let challengeId = try await identityServiceClient.startPinChange(accessToken: accessToken,
                                                                             phone: phone,
                                                                             currentPin: currentPin,
                                                                             passkeyStepUpID: nil,
                                                                             passkeyAssertion: nil)
            state.currentPin = currentPin
            state.challengeId = challengeId
            state.bindings.pin = ""
            state.errorMessage = nil
            state.phase = .enteringOtp
        } catch IdentityServiceError.invalidPin {
            state.errorMessage = L10n.screenTwoStepVerificationCurrentIncorrect
            state.bindings.pin = ""
            state.phase = .enteringCurrent
        } catch IdentityServiceError.pinLocked {
            state.errorMessage = L10n.screenTwoStepVerificationLocked
            state.phase = .overview
        } catch let IdentityServiceError.pinChangeCooldown(retry) {
            state.errorMessage = IdentityServiceError.pinChangeCooldown(retryAfterSeconds: retry).errorDescription
            state.phase = .overview
        } catch IdentityServiceError.rateLimited {
            state.errorMessage = IdentityServiceError.rateLimited.errorDescription
            state.phase = previousPhase
        } catch {
            MXLog.error("Failed to start PIN change: \(error)")
            state.errorMessage = (error as? LocalizedError)?.errorDescription ?? L10n.errorUnknown
            state.bindings.pin = ""
            state.phase = .enteringCurrent
        }
    }

    /// A passkey-authorized change never asked for the current PIN, so it retries from the new PIN.
    private var retryPhaseAfterFailedSubmission: TwoStepVerificationScreenPhase {
        state.challengeId != nil && state.currentPin.isEmpty ? .enteringNew : .enteringCurrent
    }

    private func submitNewPin(_ pin: String) async {
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
            // Only a change reaches this point: a first PIN is set inside the enrollment web session.
            guard let challengeId = state.challengeId else {
                state.errorMessage = L10n.errorUnknown
                state.phase = .overview
                return
            }
            try await identityServiceClient.completePinChange(accessToken: accessToken,
                                                              challengeId: challengeId,
                                                              otpCode: state.otpCode,
                                                              newPin: pin)
            resetFlowState()
            state.phase = .overview
            Task { await loadStatus() }
            userIndicatorController.submitIndicator(UserIndicator(id: successIndicatorID,
                                                                  type: .toast(progress: .none),
                                                                  title: L10n.screenTwoStepVerificationUpdated,
                                                                  iconName: "checkmark"))
        } catch IdentityServiceError.invalidOTP {
            state.errorMessage = L10n.screenTwoStepVerificationOtpInvalid
            state.bindings.pin = ""
            state.phase = .enteringOtp
        } catch IdentityServiceError.pinChangeChallengeInvalid {
            resetFlowState()
            // Set after the reset, which clears the message.
            state.errorMessage = IdentityServiceError.pinChangeChallengeInvalid.errorDescription
            state.phase = .overview
        } catch IdentityServiceError.invalidPin {
            let phase = retryPhaseAfterFailedSubmission
            state.errorMessage = phase == .enteringCurrent ? L10n.screenTwoStepVerificationCurrentIncorrect : L10n.errorUnknown
            state.bindings.pin = ""
            state.phase = phase
        } catch IdentityServiceError.pinLocked {
            state.errorMessage = L10n.screenTwoStepVerificationLocked
            state.phase = .overview
        } catch let IdentityServiceError.pinChangeCooldown(retry) {
            state.errorMessage = IdentityServiceError.pinChangeCooldown(retryAfterSeconds: retry).errorDescription
            state.phase = .overview
        } catch {
            MXLog.error("Failed to set or update PIN: \(error)")
            state.errorMessage = (error as? LocalizedError)?.errorDescription ?? L10n.errorUnknown
            state.bindings.pin = ""
            state.phase = retryPhaseAfterFailedSubmission
        }
    }

    private func isWeak(pin: String) -> Bool {
        let weakPins: Set = ["000000", "111111", "222222", "333333", "444444",
                             "555555", "666666", "777777", "888888", "999999",
                             "123456", "654321", "012345", "543210"]
        return weakPins.contains(pin)
    }
}
