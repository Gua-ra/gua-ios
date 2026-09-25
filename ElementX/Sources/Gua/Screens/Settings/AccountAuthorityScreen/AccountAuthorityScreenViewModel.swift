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
    /// Runs the same step-up on the sign-in origin, for a device where the native ceremony cannot run at
    /// all. `nil` means this context has no sheet to offer either.
    private let webStepUpPresenter: AuthorityWebStepUpPresenting?

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
            // The gate, not a decoration on the row: an action that arrives for a class 0x01 account leaves
            // the user where they were rather than spending a challenge and a step-up on a refusal.
            guard state.canRecoverThroughAccountRecovery else { return }
            Task { await requestStepUp(for: .recoveryThroughAccountRecovery) }
        case .enableAlerts:
            Task { await enableAlerts() }
        case let .removeAlerts(alert):
            // One tier, and this install's own row is not cheaper than any other (ADM-009 decision 13). The
            // cheaper tier this button used to take was selected by a self-asserted installation id, which
            // is a request-body field: one of a caller's values cannot authenticate another of the same
            // caller's values, so any session could empty the channel every window here rests on. The server
            // removed it, which left the factor-free button with no outcome but a refusal.
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
            // Two different answers, kept apart. A deployment with the feature off and an account with no
            // account object are both permanent, and a retry there can never succeed; anything else is a
            // read that failed and is worth trying again.
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

        // Read beside the chain rather than as part of it: neither list is the chain, and a deployment that
        // refuses one still has to show the other. A failure here leaves the list empty and says nothing
        // false about it.
        state.candidates = await (try? authorityService.candidates(accessToken: accessToken)) ?? []
        do {
            state.alerts = try await authorityService.securityAlerts(accessToken: accessToken)
            state.isAlertChannelAvailable = true
        } catch {
            state.alerts = []
            // "Not here" and "went wrong" are different answers and are kept apart. The channel has its own
            // off-by-default flag on the server, so a deployment can have the chain and not the channel, and
            // offering to turn on something that does not exist would be a promise the next window breaks.
            state.isAlertChannelAvailable = !Self.isTheChannelAbsent(error)
            if !state.isAlertChannelAvailable {
                MXLog.info("This deployment has the authority chain but not the security notification channel.")
            }
        }
    }

    // MARK: - The step-up, once, for every transition

    /// Asks for the step-up the transition is scoped to, strongest factor first, and then runs it.
    ///
    /// The order is the server's published one, with one addition that changes nothing where the first step
    /// works: a user-verifying passkey assertion settles it, **and where this device cannot produce one at
    /// all the same assertion is run in the web sheet on the sign-in origin**, which is where a simulator
    /// and a build with no associated domain for this deployment can run it. Only after both of those does
    /// the PIN come up, and only for an account that holds one.
    ///
    /// **A passkey-only account is never told to add a PIN.** That is what the sheet is for: the fallback
    /// from "the ceremony cannot run here" used to be a factor the account may not hold, and on one client
    /// platform the whole policy collapsed to PIN-only. There is no third factor anywhere in here and in
    /// particular no code sent to the account's number, which ADM-009 decision 9 forbids at every step.
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
            await askForPin(holdsPin: holdsPin, otherwise: .noFactorAtAll)
            return
        }

        switch await nativeAssertion(accessToken: accessToken) {
        case let .produced(stepUp):
            await perform(stepUp: stepUp)
        case .refusedByTheUser:
            // The person closed the system sheet, which is an answer rather than a device that cannot run
            // the ceremony. No browser is opened over the top of it.
            await askForPin(holdsPin: holdsPin, otherwise: .passkeyDidNotComplete)
        case .cannotRunHere:
            await stepUpInTheWebSheet(for: operation, accessToken: accessToken, holdsPin: holdsPin)
        }
    }

    /// What this device could make of the native ceremony. Nothing in it is ever sent anywhere: a claim
    /// that a factor is unavailable costs an attacker nothing and could only ever ask for something weaker.
    private enum NativeAssertionOutcome {
        case produced(AuthorityStepUp)
        case refusedByTheUser
        case cannotRunHere
    }

    private func nativeAssertion(accessToken: String) async -> NativeAssertionOutcome {
        guard let passkeyStepUpPresenter else {
            // This context cannot present the system sheet.
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
            // Device side: nothing reached the server, so no challenge was minted and no key was
            // generated. The passkey stays available to a later attempt, including in the sheet, which is
            // where the same credential can be asserted when this build has no associated domain for the
            // deployment it is talking to.
            MXLog.info("The passkey ceremony could not run on this device.")
            return .cannotRunHere
        }
    }

    /// Runs the step-up on the sign-in origin, in the sheet factor enrollment already uses.
    ///
    /// Scoped to the transition's own purpose, so a proof taken to root this account is not a proof for
    /// removing a device, and the server compares the stamp again when the challenge spends it. The proof
    /// itself never reaches this app: what is passed to the transition is ``AuthorityStepUp/webSheet``,
    /// which carries nothing and is read by the server off a row of its own.
    private func stepUpInTheWebSheet(for operation: AccountAuthorityScreenOperation,
                                     accessToken: String,
                                     holdsPin: Bool) async {
        guard let webStepUpPresenter, let purpose = operation.webStepUpPurpose else {
            // No sheet for this transition. Turning off an alert has two proofs and no third: an assertion
            // run natively, which did not happen or this branch would not have been reached, and the
            // account's PIN. An account that holds neither is told what is missing rather than being told
            // its passkey failed, which it did not, and it is not sent off to add a factor.
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
            // One exception to the honest "we could not confirm it was you": the deployment saying the
            // account holds nothing it can check is the same thing it says to an account with no factor at
            // all, so it gets that sentence rather than an invitation to retry forever.
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
                // Closed rather than completed. Nothing was proved, nothing was spent, and it is not
                // reported as either a success or a failure of the person's: they said no.
                leaveTheStepUp()
            }
        } catch {
            MXLog.info("The web step-up did not complete: \(error)")
            await askForPin(holdsPin: holdsPin, otherwise: .couldNotConfirm)
        }
    }

    /// Where a step-up that produced nothing leaves the reader, and what it says to them.
    private enum StepUpDeadEnd {
        /// The account holds no factor a transition can be confirmed with.
        case noFactorAtAll
        /// The passkey was there and did not go through.
        case passkeyDidNotComplete
        /// Neither ceremony could be completed. Said as what it is, without naming a factor to add.
        case couldNotConfirm
        /// Turning off an alert, on an account whose passkey this phone could not assert and which holds no
        /// PIN. The endpoint takes its factor in its own request and reads no sheet proof, so unlike every
        /// transition there is no browser route to fall back to either. The copy says what is missing and
        /// stops there: decision 13 has one removal tier and nothing weaker to offer, and telling a passkey
        /// holder to add a PIN is what C4 forbids.
        case alertsCannotBeConfirmedHere
    }

    private func askForPin(holdsPin: Bool, otherwise deadEnd: StepUpDeadEnd) async {
        guard holdsPin else {
            state.phase = state.chain == nil ? .unavailable : .overview
            // Four situations, said differently. An account that holds neither factor is told it needs
            // one, which is true of it and of nothing else; a passkey that did not go through is reported
            // as exactly that; a confirmation that could not be run anywhere says so; and turning off an
            // alert, the one step with no browser route at all, names what is missing. None of them tells a
            // passkey-only account to add a weaker factor in order to gain authority, which C4 forbids.
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

    /// Leaves a step-up that ended without a proof, saying nothing about it. Its challenge was never
    /// minted, so there is nothing to drop but the flow itself.
    private func leaveTheStepUp() {
        operation = nil
        state.phase = state.chain == nil ? .unavailable : .overview
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
                guard let stepUp else { throw AccountAuthorityServiceError.disabled }
                try await authorityService.removeSecurityAlerts(accessToken: accessToken,
                                                                accountID: chain.accountID,
                                                                installationID: installationID,
                                                                stepUp: stepUp)
                await loadChain()
            case let .oppose(pending):
                // The retry of an objection the server asked a factor for. The record it names is the one
                // the first attempt named, so a transition that settled in between is refused as stale
                // rather than being objected to in the dark.
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
            // No factor is presented first. The first opposition of an adoption needs none, and a signed
            // Oppose needs none at all: the holds gate starting a transition and never opposing one, so an
            // owner who has just changed their PIN to lock a thief out is not the one disarmed by it.
            try await authorityService.oppose(accessToken: accessToken,
                                              state: chain,
                                              pending: pending,
                                              stepUp: nil)
        } catch {
            if Self.needsAFactorToObject(error) {
                // From the second objection onward the server asks for one, on any factor and at any age,
                // so that a stolen session cannot veto the account out of ever gaining authority. It is
                // asked for and the objection is retried, exactly as every other transition here does:
                // stopping at the refusal would leave the owner with one veto and whoever started the
                // first transition only has to start a second one.
                state.phase = .overview
                await requestStepUp(for: .oppose(pending))
                return
            }
            MXLog.error("Failed opposing the pending transition: \(error)")
            state.errorMessage = message(for: error)
        }
        await loadChain()
    }

    /// Whether the objection was refused for the one reason a factor answers.
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
            // No factor: offering a public key grants nothing. What the offer is worth is decided on the
            // other phone, where a person compares the fingerprint before signing a grant over it.
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

    /// Whether the sheet was refused because the account holds nothing this deployment can check, rather
    /// than for any of the reasons a retry could survive.
    private static func holdsNoFactorThisDeploymentCanCheck(_ error: Error) -> Bool {
        guard case let IdentityServiceError.authority(refusal) = error else { return false }
        return refusal == .stepUpSheetUnavailable
    }

    /// Whether this deployment simply does not have the channel, rather than having failed to answer.
    private static func isTheChannelAbsent(_ error: Error) -> Bool {
        guard case let IdentityServiceError.authority(refusal) = error else { return false }
        return refusal.isFeatureAbsent
    }

    /// The sentence for a refusal, with one case that depends on where the step-up came from.
    ///
    /// A transition spending a sheet proof that the server will not accept for it is not an account with no
    /// two-step verification, which is what the plain `step_up_required` copy says. It is a proof the
    /// server declined to spend here, most likely because the session that took it is not the session
    /// spending it any more, and "we could not confirm it was you" is the true sentence for that. The
    /// person can open the sheet again; being told to go and set up a factor they already hold cannot help.
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
