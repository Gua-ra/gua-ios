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

/// The device lifecycle of ADM-009 as this phone can drive it: rooting a bootstrap account, offering this
/// phone's key to a trusted device, adding another device after comparing a fingerprint, objecting to what
/// is waiting, removing another device, giving up this phone's own authority, taking the recovery key back,
/// and the terminal state where none of that is possible any more.
///
/// The screen exists only while `guaAccountAuthorityEnabled` is on. Everything it reports comes from
/// `GET /account/authority`: a quarantine and a pending window are shown as what they are, with the time
/// they end, because a window nobody is told about is the defect ADM-009 gate 2 exists for and hiding one
/// in the client would be the same failure one layer up.
class AccountAuthorityScreenViewModel: AccountAuthorityScreenViewModelType, AccountAuthorityScreenViewModelProtocol {
    private let authorityService: AccountAuthorityServiceProtocol
    private let identityServiceClient: IdentityServiceClientProtocol
    private let clientProxy: ClientProxyProtocol
    private let userIndicatorController: UserIndicatorControllerProtocol
    /// Runs the passkey assertion that authorizes the transition. `nil` means this context cannot present
    /// one, which is reported as what it is rather than turned into a demand for a PIN the account may not
    /// hold.
    private let passkeyStepUpPresenter: PasskeyStepUpPresenting?

    /// The record that is built and signed, waiting on the artifact confirmation. Dropped whenever the
    /// flow is left, because its challenge is single use and its keys are unreferenced until submission.
    private var preparedRecord: PreparedAuthorityRecord?
    /// What the step-up being collected is going to authorize.
    private var operation: AccountAuthorityScreenOperation?
    /// The account's factor report, read when the step-up is about to be asked for rather than up front:
    /// which factor to offer is the only thing it is consulted for here.
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
         passkeyStepUpPresenter: PasskeyStepUpPresenting? = nil) {
        self.authorityService = authorityService
        self.identityServiceClient = identityServiceClient
        self.clientProxy = clientProxy
        self.userIndicatorController = userIndicatorController
        self.passkeyStepUpPresenter = passkeyStepUpPresenter

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
            state.comparingCandidate = candidate
            state.bindings.hasComparedFingerprint = false
            state.errorMessage = nil
            state.phase = .comparingCandidate
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
            Task { await requestStepUp(for: .recoveryThroughAccountRecovery) }
        case .enableAlerts:
            Task { await enableAlerts() }
        case let .removeAlerts(alert):
            if state.isThisInstall(alert) {
                // Tier 1: this install removing its own row needs no factor at all, because the person
                // holding this phone is the person the channel serves.
                Task { await perform(operation: .removeAlerts(installationID: alert.installationID), stepUp: nil) }
            } else {
                Task { await requestStepUp(for: .removeAlerts(installationID: alert.installationID)) }
            }
        }
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
            MXLog.error("Failed reading the account authority chain: \(error)")
            state.chain = nil
            state.phase = .unavailable
            return
        }

        // Read beside the chain rather than as part of it: neither list is the chain, and a deployment that
        // refuses one still has to show the other. A failure here leaves the list empty and says nothing
        // false about it.
        state.candidates = await (try? authorityService.candidates(accessToken: accessToken)) ?? []
        state.alerts = await (try? authorityService.securityAlerts(accessToken: accessToken)) ?? []
    }

    // MARK: - The step-up, once, for every transition

    /// Asks for the step-up the transition is scoped to, strongest factor first, and then runs it.
    ///
    /// The order is the server's published one: a user-verifying passkey assertion settles it and the PIN is
    /// not consulted. **A passkey-only account is never told to add a PIN**: when the ceremony does not
    /// produce an assertion and the account holds no PIN, what is reported is that the passkey did not
    /// complete, which is what happened. There is no third factor to reach here and in particular no code
    /// sent to the account's number, which ADM-009 decision 9 forbids at every step of this feature.
    private func requestStepUp(for operation: AccountAuthorityScreenOperation) async {
        // One transition at a time, and the phase is what says so. Two would mint two challenges and, on the
        // two records that generate keys, two key pairs, the second overwriting the first in the keychain
        // and leaving an already-signed record committing a key this phone no longer holds.
        guard !state.isWorking, let accessToken = clientProxy.accessToken else { return }
        self.operation = operation
        state.errorMessage = nil

        if factors == nil {
            factors = try? await identityServiceClient.securityStatus(accessToken: accessToken)
        }
        // A report that could not be read is not treated as "the account holds nothing": the passkey is
        // still attempted, and the PIN is still offered after it, so an unreadable report costs a prompt
        // rather than the whole transition.
        let holdsPasskey = factors?.passkeyRegistered ?? true
        let holdsPin = factors?.hasPin ?? true

        guard holdsPasskey else {
            await askForPin(holdsPin: holdsPin, afterAPasskeyAttempt: false)
            return
        }

        guard let passkeyStepUpPresenter else {
            // The account holds a passkey and this context cannot present one. Saying so is the honest
            // answer; asking a passkey-only account for a PIN it does not have would be an instruction to
            // add a weaker factor in order to gain authority, which C4 forbids outright.
            await askForPin(holdsPin: holdsPin, afterAPasskeyAttempt: true)
            return
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
            await askForPin(holdsPin: holdsPin, afterAPasskeyAttempt: true)
            return
        }
        userIndicatorController.retractIndicatorWithId(indicatorID)

        do {
            let assertion = try await passkeyStepUpPresenter.assertion(for: options)
            await perform(stepUp: .passkey(stepUpID: options.stepUpID, assertion: assertion))
        } catch {
            // Device side: nothing reached the server, so no challenge was minted and no key was
            // generated. The passkey stays available to a later attempt.
            MXLog.info("The passkey ceremony did not produce an assertion.")
            await askForPin(holdsPin: holdsPin, afterAPasskeyAttempt: true)
        }
    }

    private func askForPin(holdsPin: Bool, afterAPasskeyAttempt: Bool) async {
        guard holdsPin else {
            state.phase = .overview
            // Two different situations, said differently. An account that holds a passkey is told its
            // passkey did not go through and can try again; an account that holds neither factor is told it
            // needs one, which is true of it and of nothing else.
            state.errorMessage = afterAPasskeyAttempt
                ? L10n.screenAccountAuthorityErrorPasskeyIncomplete
                : L10n.screenAccountAuthorityErrorStepUp
            return
        }
        state.bindings.pin = ""
        state.phase = .enteringPin
    }

    private func perform(stepUp: AuthorityStepUp) async {
        guard let operation else { return }
        await perform(operation: operation, stepUp: stepUp)
    }

    /// Runs one transition with the step-up that was just collected.
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
                // The account holder gave no reason, and the app does not invent one: the reason byte is
                // inside the signed record and is what a notification to the other devices may name.
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
                try await authorityService.removeSecurityAlerts(accessToken: accessToken,
                                                                accountID: chain.accountID,
                                                                installationID: installationID,
                                                                stepUp: stepUp)
                await loadChain()
            }
        } catch {
            MXLog.error("Failed running an authority transition: \(error)")
            state.errorMessage = message(for: error)
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

        // The confirmation is recorded on the prepared record, which is the only thing that lets it be
        // submitted at all, and it wipes the key from memory as it does: shown once means shown once.
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
        // The window is what the reader needs now, and the server is the only thing that knows when it
        // ends, so the screen re-reads rather than predicting it.
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
            // No factor is presented. The first opposition of an adoption needs none, and a signed Oppose
            // needs none either: the holds gate starting a transition and never opposing one, so an owner
            // who has just changed their PIN to lock a thief out is not the one disarmed by it.
            try await authorityService.oppose(accessToken: accessToken,
                                              state: chain,
                                              pending: pending,
                                              stepUp: nil)
        } catch {
            MXLog.error("Failed opposing the pending transition: \(error)")
            state.errorMessage = message(for: error)
        }
        await loadChain()
    }

    // MARK: - Devices

    private func offerThisDevice() async {
        guard let accessToken = clientProxy.accessToken, let chain = state.chain else { return }
        state.errorMessage = nil
        state.phase = .steppingUp
        do {
            // No factor: offering a public key grants nothing. What the offer is worth is decided on the
            // other phone, where a person compares the fingerprint before signing a grant over it.
            let offer = try await authorityService.offerThisDevice(accessToken: accessToken,
                                                                   accountID: chain.accountID)
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
        // Local to this device and short lived. The key is generated non-synced and never rides iCloud
        // Keychain, so handing it to Universal Clipboard would undo that in one tap, and a key material
        // pasteboard that never expires is one an app opened hours later can still read.
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: artifact]],
                                      options: [.localOnly: true,
                                                .expirationDate: Date().addingTimeInterval(120)])
        userIndicatorController.submitIndicator(UserIndicator(id: copyIndicatorID,
                                                              title: L10n.screenAccountAuthorityArtifactCopied,
                                                              iconName: "checkmark"))
    }

    /// Leaves the flow, dropping whatever was prepared.
    ///
    /// Its challenge is single use and its keys are unreferenced until a record carrying them is on the
    /// chain, so an abandoned preparation costs nothing and leaves nothing half-rooted: the chain either
    /// has the record or it does not.
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

    private func message(for error: Error) -> String {
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
