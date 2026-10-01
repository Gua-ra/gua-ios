//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

typealias AccountAuthorityScreenViewModelType = StateStoreViewModelV2<AccountAuthorityScreenViewState, AccountAuthorityScreenViewAction>

class AccountAuthorityScreenViewModel: AccountAuthorityScreenViewModelType, AccountAuthorityScreenViewModelProtocol {
    private let authorityService: AccountAuthorityServiceProtocol
    private let identityServiceClient: IdentityServiceClientProtocol
    private let clientProxy: ClientProxyProtocol
    private let userIndicatorController: UserIndicatorControllerProtocol
    private let passkeyStepUpPresenter: PasskeyStepUpPresenting?
    private let webStepUpPresenter: AuthorityWebStepUpPresenting?

    private var preparedRecord: PreparedAuthorityRecord?
    private var operation: AccountAuthorityScreenOperation?
    private var factors: AccountSecurityStatus?

    private let indicatorID = "AccountAuthorityScreen-Working"
    private let copyIndicatorID = "AccountAuthorityScreen-Copied"

    private let actionsSubject: PassthroughSubject<AccountAuthorityScreenViewModelAction, Never> = .init()
    var actionsPublisher: AnyPublisher<AccountAuthorityScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(authorityService: AccountAuthorityServiceProtocol,
         identityServiceClient: IdentityServiceClientProtocol,
         clientProxy: ClientProxyProtocol,
         userIndicatorController: UserIndicatorControllerProtocol,
         passkeyStepUpPresenter: PasskeyStepUpPresenting? = nil,
         webStepUpPresenter: AuthorityWebStepUpPresenting? = nil) {
        self.authorityService = authorityService
        self.identityServiceClient = identityServiceClient
        self.clientProxy = clientProxy
        self.userIndicatorController = userIndicatorController
        self.passkeyStepUpPresenter = passkeyStepUpPresenter
        self.webStepUpPresenter = webStepUpPresenter

        super.init(initialViewState: AccountAuthorityScreenViewState())

        Task { await loadChain() }
    }

    override func process(viewAction: AccountAuthorityScreenViewAction) {
        switch viewAction {
        case .retry:
            Task { await loadChain() }
        case .startAdoption:
            guard state.phase == .overview, state.canAdopt else { return }
            Task { await requestStepUp(for: .adoption) }
        case .pinChanged:
            let cleaned = String(state.bindings.pin.filter(\.isNumber).prefix(AccountAuthorityScreenViewState.pinLength))
            if cleaned != state.bindings.pin {
                state.bindings.pin = cleaned
            }
            if state.errorMessage != nil { state.errorMessage = nil }
            if state.canSubmitPin {
                let pin = cleaned
                state.bindings.pin = ""
                Task { await perform(stepUp: .pin(pin)) }
            }
        case .pinSubmitted:
            guard state.canSubmitPin else { return }
            let pin = state.bindings.pin
            state.bindings.pin = ""
            Task { await perform(stepUp: .pin(pin)) }
        case .copyRecoveryArtifact:
            copyRecoveryArtifact()
        case .submitArtifact:
            Task { await submitPreparedRecord() }
        case .cancel:
            leaveFlow()
        case .showApprovals:
            actionsSubject.send(.showApprovals)
        case .opposePending:
            Task { await opposePending() }
        case .offerThisDevice:
            Task { await offerThisDevice() }
        case let .compareCandidate(candidate):
            startComparing(candidate)
        case .signGrant:
            guard state.canSignGrant, let candidate = state.comparingCandidate else { return }
            Task { await requestStepUp(for: .grant(candidate)) }
        case let .revokeDevice(device):
            guard state.canActAsAnAuthorityDevice, !state.isThisDevice(device) else { return }
            Task { await requestStepUp(for: .revokeAnother(deviceKey: device.deviceKey, label: device.label)) }
        case .revokeThisDevice:
            guard let thisDeviceKey = state.thisDeviceKey else { return }
            Task { await requestStepUp(for: .revokeThisDevice(deviceKey: thisDeviceKey)) }
        case .startRecovery:
            state.bindings.recoveryArtifact = ""
            state.errorMessage = nil
            state.phase = .enteringRecoveryArtifact
        case .recoveryArtifactChanged:
            if state.errorMessage != nil { state.errorMessage = nil }
        case .submitRecoveryArtifact:
            guard state.canSubmitRecoveryArtifact else { return }
            Task { await requestStepUp(for: .recoveryWithArtifact(state.bindings.recoveryArtifact)) }
        case .startRecoveryThroughAccountRecovery:
            guard state.canRecoverThroughAccountRecovery else { return }
            Task { await requestStepUp(for: .recoveryThroughAccountRecovery) }
        case .enableAlerts:
            Task { await enableAlerts() }
        case let .removeAlerts(alert):
            Task { await requestStepUp(for: .removeAlerts(installationID: alert.installationID)) }
        }
    }

    private func startComparing(_ candidate: AuthorityCandidate) {
        state.comparingCandidate = candidate
        state.bindings.hasComparedFingerprint = false
        state.errorMessage = nil
        state.phase = .comparingCandidate
    }

    // MARK: - Reading the chain

    private func loadChain() async {
        guard let accessToken = clientProxy.accessToken else {
            state.phase = .unavailable
            return
        }
        state.phase = .loading
        do {
            let chain = try await authorityService.state(accessToken: accessToken)
            state.chain = chain
            state.thisDeviceKey = authorityService.thisDeviceKey(accountID: chain.accountID)
            state.thisInstallationID = authorityService.thisInstallationID()
            state.phase = .overview
        } catch {
            let refusal = error as? AuthorityRefusal
            let permanent = refusal == .disabled || refusal == .noAccount
            if !permanent {
                MXLog.error("Failed reading the account authority chain: \(error)")
            }
            state.chain = nil
            state.isUnavailablePermanently = permanent
            state.phase = .unavailable
            return
        }

        state.candidates = await (try? authorityService.candidates(accessToken: accessToken)) ?? []
        do {
            state.alerts = try await authorityService.securityAlerts(accessToken: accessToken)
            state.isAlertChannelAvailable = true
        } catch {
            state.alerts = []
            state.isAlertChannelAvailable = !Self.isTheChannelAbsent(error)
            if !state.isAlertChannelAvailable {
                MXLog.info("This deployment has the authority chain but not the security notification channel.")
            }
        }
    }

    // MARK: - The step-up, once, for every transition

    /// Native passkey first, then the web sheet where the native ceremony cannot run, then the PIN. Never a code sent to the phone number.
    private func requestStepUp(for operation: AccountAuthorityScreenOperation) async {
        // One transition at a time: a second would overwrite the first key pair in the keychain.
        guard !state.isWorking, let accessToken = clientProxy.accessToken else { return }
        self.operation = operation
        state.errorMessage = nil

        if factors == nil {
            factors = try? await identityServiceClient.securityStatus(accessToken: accessToken)
        }
        // An unreadable factor report is not read as "no factors".
        let holdsPasskey = factors?.passkeyRegistered ?? true
        let holdsPin = factors?.hasPin ?? true

        guard holdsPasskey else {
            await askForPin(holdsPin: holdsPin, otherwise: .noFactorAtAll)
            return
        }

        switch await nativeAssertion(accessToken: accessToken) {
        case let .produced(stepUp):
            await perform(stepUp: stepUp)
        case .refusedByTheUser:
            await askForPin(holdsPin: holdsPin, otherwise: .passkeyDidNotComplete)
        case .cannotRunHere:
            await stepUpInTheWebSheet(for: operation, accessToken: accessToken, holdsPin: holdsPin)
        }
    }

    private enum NativeAssertionOutcome {
        case produced(AuthorityStepUp)
        case refusedByTheUser
        case cannotRunHere
    }

    private func nativeAssertion(accessToken: String) async -> NativeAssertionOutcome {
        guard let passkeyStepUpPresenter else {
            return .cannotRunHere
        }

        state.phase = .steppingUp
        userIndicatorController.submitIndicator(UserIndicator(id: indicatorID,
                                                              type: .modal,
                                                              title: L10n.commonLoading,
                                                              persistent: true))
        let options: PasskeyStepUpOptions
        do {
            options = try await identityServiceClient.startPasskeyStepUp(accessToken: accessToken)
        } catch {
            userIndicatorController.retractIndicatorWithId(indicatorID)
            MXLog.info("The deployment would not mint a passkey ceremony for this account.")
            return .cannotRunHere
        }
        userIndicatorController.retractIndicatorWithId(indicatorID)

        do {
            let assertion = try await passkeyStepUpPresenter.assertion(for: options)
            return .produced(.passkey(stepUpID: options.stepUpID, assertion: assertion))
        } catch PasskeyStepUpError.cancelled {
            MXLog.info("The passkey sheet was dismissed.")
            return .refusedByTheUser
        } catch {
            MXLog.info("The passkey ceremony could not run on this device.")
            return .cannotRunHere
        }
    }

    private func stepUpInTheWebSheet(for operation: AccountAuthorityScreenOperation,
                                     accessToken: String,
                                     holdsPin: Bool) async {
        guard let webStepUpPresenter, let purpose = operation.webStepUpPurpose else {
            let deadEnd: StepUpDeadEnd = switch operation {
            case .removeAlerts: .alertsCannotBeConfirmedHere
            default: .passkeyDidNotComplete
            }
            await askForPin(holdsPin: holdsPin, otherwise: deadEnd)
            return
        }

        state.phase = .steppingUp
        userIndicatorController.submitIndicator(UserIndicator(id: indicatorID,
                                                              type: .modal,
                                                              title: L10n.commonLoading,
                                                              persistent: true))
        let url: URL
        do {
            url = try await authorityService.webStepUpURL(accessToken: accessToken, purpose: purpose)
        } catch {
            userIndicatorController.retractIndicatorWithId(indicatorID)
            MXLog.info("This deployment would not open a web step-up for this transition: \(error)")
            let deadEnd: StepUpDeadEnd = Self.holdsNoFactorThisDeploymentCanCheck(error) ? .noFactorAtAll : .couldNotConfirm
            await askForPin(holdsPin: holdsPin, otherwise: deadEnd)
            return
        }
        userIndicatorController.retractIndicatorWithId(indicatorID)

        do {
            switch try await webStepUpPresenter.present(url) {
            case .returned:
                await perform(stepUp: .webSheet)
            case .dismissed:
                leaveTheStepUp()
            }
        } catch {
            MXLog.info("The web step-up did not complete: \(error)")
            await askForPin(holdsPin: holdsPin, otherwise: .couldNotConfirm)
        }
    }

    private enum StepUpDeadEnd {
        case noFactorAtAll
        case passkeyDidNotComplete
        case couldNotConfirm
        /// Removing an alert has no web-sheet route: its endpoint takes the factor in the request itself.
        case alertsCannotBeConfirmedHere
    }

    private func askForPin(holdsPin: Bool, otherwise deadEnd: StepUpDeadEnd) async {
        guard holdsPin else {
            state.phase = state.chain == nil ? .unavailable : .overview
            state.errorMessage = switch deadEnd {
            case .noFactorAtAll: L10n.screenAccountAuthorityErrorStepUp
            case .passkeyDidNotComplete: L10n.screenAccountAuthorityErrorPasskeyIncomplete
            case .couldNotConfirm: L10n.screenAccountAuthorityErrorConfirmationIncomplete
            case .alertsCannotBeConfirmedHere: L10n.screenAccountAuthorityErrorAlertsStepUp
            }
            operation = nil
            return
        }
        state.bindings.pin = ""
        state.phase = .enteringPin
    }

    private func leaveTheStepUp() {
        operation = nil
        state.phase = state.chain == nil ? .unavailable : .overview
    }

    private func perform(stepUp: AuthorityStepUp) async {
        guard let operation else { return }
        await perform(operation: operation, stepUp: stepUp)
    }

    private func perform(operation: AccountAuthorityScreenOperation, stepUp: AuthorityStepUp?) async {
        guard let accessToken = clientProxy.accessToken, let chain = state.chain else { return }
        state.phase = .steppingUp
        userIndicatorController.submitIndicator(UserIndicator(id: indicatorID,
                                                              type: .modal,
                                                              title: L10n.commonLoading,
                                                              persistent: true))
        defer { userIndicatorController.retractIndicatorWithId(indicatorID) }

        do {
            switch operation {
            case .adoption:
                guard let stepUp else { throw AccountAuthorityServiceError.disabled }
                let prepared = try await authorityService.prepareAdoption(accessToken: accessToken,
                                                                          accountID: chain.accountID,
                                                                          stepUp: stepUp)
                present(prepared)
            case let .recoveryWithArtifact(typed):
                guard let stepUp else { throw AccountAuthorityServiceError.disabled }
                let prepared = try await authorityService.prepareRecovery(accessToken: accessToken,
                                                                          state: chain,
                                                                          typedArtifact: typed,
                                                                          stepUp: stepUp)
                state.bindings.recoveryArtifact = ""
                present(prepared)
            case .recoveryThroughAccountRecovery:
                guard let stepUp else { throw AccountAuthorityServiceError.disabled }
                let prepared = try await authorityService
                    .prepareRecoveryThroughAccountRecovery(accessToken: accessToken,
                                                           state: chain,
                                                           stepUp: stepUp)
                present(prepared)
            case let .grant(candidate):
                guard let stepUp else { throw AccountAuthorityServiceError.disabled }
                _ = try await authorityService.signDeviceGrant(accessToken: accessToken,
                                                               state: chain,
                                                               candidate: candidate,
                                                               comparisonConfirmed: state.bindings.hasComparedFingerprint,
                                                               stepUp: stepUp)
                state.comparingCandidate = nil
                state.bindings.hasComparedFingerprint = false
                await loadChain()
            case let .revokeAnother(deviceKey, _):
                guard let stepUp else { throw AccountAuthorityServiceError.disabled }
                _ = try await authorityService.revokeDevice(accessToken: accessToken,
                                                            state: chain,
                                                            deviceKey: deviceKey,
                                                            reason: AuthorityRecord.reasonUnspecified,
                                                            stepUp: stepUp)
                await loadChain()
            case let .revokeThisDevice(deviceKey):
                guard let stepUp else { throw AccountAuthorityServiceError.disabled }
                _ = try await authorityService.revokeDevice(accessToken: accessToken,
                                                            state: chain,
                                                            deviceKey: deviceKey,
                                                            reason: AuthorityRecord.reasonReplaced,
                                                            stepUp: stepUp)
                await loadChain()
            case let .removeAlerts(installationID):
                guard let stepUp else { throw AccountAuthorityServiceError.disabled }
                try await authorityService.removeSecurityAlerts(accessToken: accessToken,
                                                                accountID: chain.accountID,
                                                                installationID: installationID,
                                                                stepUp: stepUp)
                await loadChain()
            case let .oppose(pending):
                guard let stepUp else { throw AccountAuthorityServiceError.disabled }
                try await authorityService.oppose(accessToken: accessToken,
                                                  state: chain,
                                                  pending: pending,
                                                  stepUp: stepUp)
                await loadChain()
            }
        } catch {
            MXLog.error("Failed running an authority transition: \(error)")
            state.errorMessage = message(for: error, afterASheetProof: stepUp == .webSheet)
            state.phase = state.chain == nil ? .unavailable : .overview
        }
        self.operation = nil
    }

    private func present(_ prepared: PreparedAuthorityRecord) {
        preparedRecord = prepared
        state.recoveryArtifact = prepared.recoveryArtifact
        state.artifactKind = prepared.kind
        state.bindings.hasStoredRecoveryArtifact = false
        state.phase = .artifact
    }

    private func submitPreparedRecord() async {
        guard state.canSubmitArtifact,
              let prepared = preparedRecord,
              let accessToken = clientProxy.accessToken else { return }

        prepared.confirmArtifactStored()
        state.recoveryArtifact = nil
        state.phase = .submitting

        do {
            _ = try await authorityService.submit(accessToken: accessToken, prepared: prepared)
            preparedRecord = nil
        } catch {
            MXLog.error("Failed submitting an authority record: \(error)")
            preparedRecord = nil
            state.errorMessage = message(for: error)
        }
        await loadChain()
    }

    // MARK: - Opposition

    private func opposePending() async {
        guard let accessToken = clientProxy.accessToken,
              let chain = state.chain,
              let pending = chain.pending else { return }
        state.errorMessage = nil
        state.phase = .submitting
        do {
            try await authorityService.oppose(accessToken: accessToken,
                                              state: chain,
                                              pending: pending,
                                              stepUp: nil)
        } catch {
            if Self.needsAFactorToObject(error) {
                state.phase = .overview
                await requestStepUp(for: .oppose(pending))
                return
            }
            MXLog.error("Failed opposing the pending transition: \(error)")
            state.errorMessage = message(for: error)
        }
        await loadChain()
    }

    private static func needsAFactorToObject(_ error: Error) -> Bool {
        guard case let IdentityServiceError.authority(refusal) = error else { return false }
        return refusal == .stepUpRequired
    }

    // MARK: - Devices

    private func offerThisDevice() async {
        guard let accessToken = clientProxy.accessToken, let chain = state.chain else { return }
        state.errorMessage = nil
        state.phase = .steppingUp
        do {
            let offer = try await authorityService.offerThisDevice(accessToken: accessToken, state: chain)
            state.ownOffer = offer
            state.phase = .offeringThisDevice
        } catch {
            MXLog.error("Failed offering this device's key: \(error)")
            state.errorMessage = message(for: error)
            state.phase = .overview
        }
    }

    // MARK: - Security alerts

    private func enableAlerts() async {
        guard let accessToken = clientProxy.accessToken, let chain = state.chain else { return }
        state.errorMessage = nil
        state.phase = .submitting
        do {
            _ = try await authorityService.registerSecurityAlerts(accessToken: accessToken,
                                                                  accountID: chain.accountID)
        } catch {
            MXLog.error("Failed registering this install for security alerts: \(error)")
            state.errorMessage = message(for: error)
        }
        await loadChain()
    }

    private func copyRecoveryArtifact() {
        guard let artifact = state.recoveryArtifact else { return }
        // Local-only and expiring, so the key never reaches Universal Clipboard.
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: artifact]],
                                      options: [.localOnly: true,
                                                .expirationDate: Date().addingTimeInterval(120)])
        userIndicatorController.submitIndicator(UserIndicator(id: copyIndicatorID,
                                                              title: L10n.screenAccountAuthorityArtifactCopied,
                                                              iconName: "checkmark"))
    }

    private func leaveFlow() {
        preparedRecord = nil
        operation = nil
        state.recoveryArtifact = nil
        state.comparingCandidate = nil
        state.ownOffer = nil
        state.bindings.pin = ""
        state.bindings.recoveryArtifact = ""
        state.bindings.hasStoredRecoveryArtifact = false
        state.bindings.hasComparedFingerprint = false
        state.errorMessage = nil
        state.phase = state.chain == nil ? .unavailable : .overview
    }

    private static func holdsNoFactorThisDeploymentCanCheck(_ error: Error) -> Bool {
        guard case let IdentityServiceError.authority(refusal) = error else { return false }
        return refusal == .stepUpSheetUnavailable
    }

    private static func isTheChannelAbsent(_ error: Error) -> Bool {
        guard case let IdentityServiceError.authority(refusal) = error else { return false }
        return refusal.isFeatureAbsent
    }

    /// After a sheet proof, `step_up_required` means the server declined that proof, not that the account lacks a factor.
    private func message(for error: Error, afterASheetProof: Bool = false) -> String {
        if afterASheetProof, case IdentityServiceError.authority(.stepUpRequired) = error {
            return L10n.screenAccountAuthorityErrorConfirmationIncomplete
        }
        switch error {
        case AccountAuthorityServiceError.artifactUnconfirmed:
            return L10n.screenAccountAuthorityArtifactConfirm
        case AccountAuthorityServiceError.artifactMalformed:
            return L10n.screenAccountAuthorityRecoveryMalformed
        case AccountAuthorityServiceError.artifactNotThisAccount:
            return L10n.screenAccountAuthorityRecoveryNotThisAccount
        case AccountAuthorityServiceError.candidateUnverified:
            return L10n.screenAccountAuthorityCandidateUnverified
        case AccountAuthorityServiceError.notAnAuthorityDevice:
            return L10n.screenAccountAuthorityErrorNotThisDevice
        case AccountAuthorityServiceError.noPushToken:
            return L10n.screenAccountAuthorityAlertsUnavailable
        default:
            return (error as? LocalizedError)?.errorDescription ?? L10n.errorUnknown
        }
    }
}
