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
    /// present one, which reads exactly like a device that cannot produce an assertion: the current
    /// PIN is asked for instead. It is never turned into a claim to the server.
    private let passkeyStepUpPresenter: PasskeyStepUpPresenting?
    /// Set once the server has refused this flow's passkey (too new, not verified, not this
    /// account's). Running the ceremony again would reach the same answer, so the rest of the flow
    /// asks for the PIN. A new change starts clean.
    private var passkeyRefusedThisFlow = false

    private let actionsSubject: PassthroughSubject<TwoStepVerificationScreenViewModelAction, Never> = .init()
    var actionsPublisher: AnyPublisher<TwoStepVerificationScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    /// A factor the caller asked this screen to set up on arrival, from the change-phone block
    /// screen. It decides which setup opens, which is the whole point of carrying it: the block
    /// screen offers a choice and this honours it instead of always opening PIN setup.
    private let initialSetup: AuthFactor?
    /// One shot. The screen honours the arriving request once; a later reload must not reopen a
    /// ceremony the user has already dealt with.
    private var appliedInitialSetup = false

    private let indicatorID = "TwoStepVerificationScreen-Submit"
    private let successIndicatorID = "TwoStepVerificationScreen-Success"

    /// What the account holds. Read from the server rather than assembled here, so this screen, the
    /// change-phone step-up and the home-screen nudge all answer "which factor" the same way.
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
            resetFlowState()
            state.phase = .enteringNew
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
            // The view model can't present a web sheet; the coordinator does.
            actionsSubject.send(.setUpPasskey)
        }
    }

    // MARK: - Flow control

    private func resetFlowState() {
        passkeyRefusedThisFlow = false
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

    /// Strips an international prefix ("+1…" or a redundant leading dial code) that iOS
    /// autofill pastes into the local-number field, switching the country when needed.
    /// Mirrors the same method in `PhoneEntryScreenViewModel`.
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

    /// Rewrites the local phone digits with the country-specific live-formatted version
    /// (e.g. `"51985550619"` → `"(51) 98555-0619"`), mirroring the sign-up phone screen.
    private func reformatNumber() {
        let digits = state.bindings.localPhoneNumber.filter(\.isNumber)
        let formatted = state.selectedCountry.formatNational(digits: digits)
        if formatted != state.bindings.localPhoneNumber {
            state.bindings.localPhoneNumber = formatted
        }
    }

    /// Recomputes `selectedCountry` from the typed digits (e.g. typing a Canadian area code
    /// flips the flag from US to CA), matching the sign-up phone screen's behaviour.
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
        // Strongest factor first: an account holding a passkey is asked for it before its PIN, and
        // the PIN stays underneath for whenever the assertion is not produced or not accepted.
        if state.factors?.passkeyRegistered == true, !passkeyRefusedThisFlow, let passkeyStepUpPresenter {
            Task { await authorizeWithPasskeyAndRequestOtp(presenter: passkeyStepUpPresenter) }
            return
        }
        state.phase = .enteringCurrent
    }

    private func handleSubmittedCode(_ code: String) {
        switch state.phase {
        case .enteringCurrent:
            // Validate against the backend immediately before allowing progression.
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
            // A report that could not be read leaves `factors` nil. It must not collapse into "no
            // PIN": that read is what told a passkey holder their account had nothing, and it would
            // be worse now that the same screen speaks about passkeys too. The overview says the
            // status is unavailable and offers a retry.
            MXLog.error("Failed to fetch the account's factor status: \(error)")
            state.factors = nil
            state.phase = .overview
            state.errorMessage = (error as? LocalizedError)?.errorDescription ?? L10n.errorUnknown
        }
    }

    /// Opens the setup the caller asked for, once the report says it is still needed. A factor the
    /// account already holds opens nothing, so arriving here twice cannot start a ceremony that is
    /// certain to fail.
    private func applyInitialSetup() {
        guard !appliedInitialSetup else { return }
        appliedInitialSetup = true
        switch initialSetup {
        case .passkey where !(state.factors?.passkeyRegistered ?? true):
            actionsSubject.send(.setUpPasskey)
        case .pin where !userHasPin:
            resetFlowState()
            state.phase = .enteringNew
        default:
            break
        }
    }

    /// Authorizes the change with a passkey assertion and, once the server accepts it, goes straight to
    /// the code it texted. The current PIN is never asked for on this path.
    ///
    /// Anything that stops the assertion from being accepted lands on the current-PIN step, which is
    /// the path every PIN holder had before. The server is told nothing about why: "my passkey is
    /// unavailable" costs nothing to claim, so it could only ever ask for something weaker.
    private func authorizeWithPasskeyAndRequestOtp(presenter: PasskeyStepUpPresenting) async {
        guard let accessToken = clientProxy.accessToken else {
            state.errorMessage = L10n.errorUnknown
            return
        }
        let phone = state.phone
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
            // The server would not mint the ceremony, so asking again in this flow repeats the refusal.
            passkeyRefusedThisFlow = true
            fallBackToCurrentPin(message: L10n.screenChangePhonePasskeyFallback)
            return
        }
        userIndicatorController.retractIndicatorWithId(indicatorID)

        let assertion: PasskeyAssertion
        do {
            assertion = try await presenter.assertion(for: options)
        } catch {
            // Device side: nothing reached the server, so the passkey stays available to a later try.
            if let stepUpError = error as? PasskeyStepUpError, case .cancelled = stepUpError {
                fallBackToCurrentPin(message: nil)
            } else {
                fallBackToCurrentPin(message: L10n.screenChangePhonePasskeyFallback)
            }
            return
        }

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
            state.challengeId = challengeId
            state.bindings.pin = ""
            state.errorMessage = nil
            state.phase = .enteringOtp
        } catch IdentityServiceError.pinLocked {
            state.errorMessage = L10n.screenTwoStepVerificationLocked
            state.phase = .overview
        } catch let IdentityServiceError.pinChangeCooldown(retry) {
            state.errorMessage = IdentityServiceError.pinChangeCooldown(retryAfterSeconds: retry).errorDescription
            state.phase = .overview
        } catch IdentityServiceError.rateLimited {
            state.errorMessage = IdentityServiceError.rateLimited.errorDescription
            state.phase = .enteringPhone
        } catch {
            // Refused by the server: a passkey registered too recently, one that did not verify the
            // user, or one that is not this account's (which also arrives as invalid_pin). The
            // ceremony is spent either way, and the PIN has not been consulted.
            MXLog.info("The server refused the passkey for this PIN change; asking for the current PIN: \(error)")
            passkeyRefusedThisFlow = true
            fallBackToCurrentPin(message: L10n.screenChangePhonePasskeyFallback)
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
            if userHasPin {
                guard let challengeId = state.challengeId else {
                    state.errorMessage = L10n.errorUnknown
                    state.phase = .overview
                    return
                }
                try await identityServiceClient.completePinChange(accessToken: accessToken,
                                                                  challengeId: challengeId,
                                                                  otpCode: state.otpCode,
                                                                  newPin: pin)
            } else {
                try await identityServiceClient.setInitialPin(accessToken: accessToken,
                                                              userId: clientProxy.userID,
                                                              newPin: pin)
            }
            // The PIN now exists. Re-read the report rather than patching a local copy of it, so
            // this screen keeps saying what the server says.
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
            state.errorMessage = IdentityServiceError.pinChangeChallengeInvalid.errorDescription
            resetFlowState()
            state.phase = .overview
        } catch IdentityServiceError.invalidPin {
            state.errorMessage = L10n.screenTwoStepVerificationCurrentIncorrect
            state.bindings.pin = ""
            state.phase = userHasPin ? .enteringCurrent : .enteringNew
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
            state.phase = userHasPin ? .enteringCurrent : .enteringNew
        }
    }

    private func isWeak(pin: String) -> Bool {
        let weakPins: Set = ["000000", "111111", "222222", "333333", "444444",
                             "555555", "666666", "777777", "888888", "999999",
                             "123456", "654321", "012345", "543210"]
        return weakPins.contains(pin)
    }
}
