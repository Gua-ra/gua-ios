//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Combine
import SwiftUI
import UIKit

typealias AccountAuthorityScreenViewModelType = StateStoreViewModelV2<AccountAuthorityScreenViewState, AccountAuthorityScreenViewAction>

/// The device set of ADM-009 as this phone can read it, and the one transition this phone can open:
/// rooting a bootstrap account on itself.
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
    /// one, which reads exactly like a device that cannot produce one: the PIN is asked for instead, and
    /// the server is never told that a passkey was unavailable.
    private let passkeyStepUpPresenter: PasskeyStepUpPresenting?

    /// The adoption that is built and signed, waiting on the artifact confirmation. Dropped whenever the
    /// flow is left, because its challenge is single use and its keys are garbage until it is submitted.
    private var preparedAdoption: PreparedAdoption?
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
            Task { await startAdoption() }
        case .pinChanged:
            let cleaned = String(state.bindings.pin.filter(\.isNumber).prefix(AccountAuthorityScreenViewState.pinLength))
            if cleaned != state.bindings.pin {
                state.bindings.pin = cleaned
            }
            if state.errorMessage != nil { state.errorMessage = nil }
            if state.canSubmitPin {
                let pin = cleaned
                state.bindings.pin = ""
                Task { await prepareAdoption(stepUp: .pin(pin)) }
            }
        case .pinSubmitted:
            guard state.canSubmitPin else { return }
            let pin = state.bindings.pin
            state.bindings.pin = ""
            Task { await prepareAdoption(stepUp: .pin(pin)) }
        case .copyRecoveryArtifact:
            copyRecoveryArtifact()
        case .submitAdoption:
            Task { await submitAdoption() }
        case .cancel:
            leaveFlow()
        case .showApprovals:
            actionsSubject.send(.showApprovals)
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
            state.phase = .overview
        } catch {
            MXLog.error("Failed reading the account authority chain: \(error)")
            state.chain = nil
            state.phase = .unavailable
        }
    }

    // MARK: - Adoption

    /// Asks for the step-up the transition is scoped to, strongest factor first.
    ///
    /// The order is the server's published one: a user-verifying passkey assertion settles it and the PIN
    /// is not consulted. Whatever happens inside the ceremony stays on this device and turns into "ask for
    /// the next factor", never into a claim sent to the server that a passkey was unavailable.
    private func startAdoption() async {
        guard state.canAdopt, let accessToken = clientProxy.accessToken else { return }
        state.errorMessage = nil

        if factors == nil {
            factors = try? await identityServiceClient.securityStatus(accessToken: accessToken)
        }
        // A report that could not be read is not treated as "the account holds nothing": the passkey is
        // still attempted, and the PIN is still offered after it, so an unreadable report costs a prompt
        // rather than the whole transition.
        let holdsPasskey = factors?.passkeyRegistered ?? true
        let holdsPin = factors?.hasPin ?? true

        if holdsPasskey, let passkeyStepUpPresenter {
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
                await fallBackToPin(holdsPin: holdsPin)
                return
            }
            userIndicatorController.retractIndicatorWithId(indicatorID)

            do {
                let assertion = try await passkeyStepUpPresenter.assertion(for: options)
                await prepareAdoption(stepUp: .passkey(stepUpID: options.stepUpID, assertion: assertion))
            } catch {
                // Device side: nothing reached the server, so no challenge was minted and no key was
                // generated. The passkey stays available to a later attempt.
                MXLog.info("The passkey ceremony did not produce an assertion.")
                await fallBackToPin(holdsPin: holdsPin)
            }
            return
        }

        await fallBackToPin(holdsPin: holdsPin)
    }

    private func fallBackToPin(holdsPin: Bool) async {
        guard holdsPin else {
            // The account can produce neither factor. There is no third one to reach here, and in
            // particular no code sent to the account's number: ADM-009 decision 9 forbids it at every
            // step of this feature, in any combination.
            state.phase = .overview
            state.errorMessage = L10n.screenAccountAuthorityErrorStepUp
            return
        }
        state.bindings.pin = ""
        state.phase = .enteringPin
    }

    /// Mints the challenge with that step-up, generates the two keys, and builds and signs the record.
    /// Nothing has reached the chain when this returns: the next step is the artifact.
    private func prepareAdoption(stepUp: AuthorityStepUp) async {
        guard let accessToken = clientProxy.accessToken, let chain = state.chain else { return }
        state.phase = .steppingUp
        userIndicatorController.submitIndicator(UserIndicator(id: indicatorID,
                                                              type: .modal,
                                                              title: L10n.commonLoading,
                                                              persistent: true))
        defer { userIndicatorController.retractIndicatorWithId(indicatorID) }

        do {
            let prepared = try await authorityService.prepareAdoption(accessToken: accessToken,
                                                                      accountID: chain.accountID,
                                                                      stepUp: stepUp)
            preparedAdoption = prepared
            state.recoveryArtifact = prepared.recoveryArtifact
            state.bindings.hasStoredRecoveryArtifact = false
            state.phase = .artifact
        } catch {
            MXLog.error("Failed preparing the adoption: \(error)")
            state.errorMessage = message(for: error)
            state.phase = .overview
        }
    }

    private func submitAdoption() async {
        guard state.canSubmitAdoption,
              let prepared = preparedAdoption,
              let accessToken = clientProxy.accessToken else { return }

        // The confirmation is recorded on the prepared adoption, which is the only thing that lets it be
        // submitted at all, and it wipes the key from memory as it does: shown once means shown once.
        prepared.confirmArtifactStored()
        state.recoveryArtifact = nil
        state.phase = .submitting

        do {
            _ = try await authorityService.submitAdoption(accessToken: accessToken, prepared: prepared)
            preparedAdoption = nil
            // The window is what the reader needs now, and the server is the only thing that knows when
            // it ends, so the screen re-reads rather than predicting it.
            await loadChain()
        } catch {
            MXLog.error("Failed submitting the adoption: \(error)")
            preparedAdoption = nil
            state.errorMessage = message(for: error)
            await loadChain()
        }
    }

    private func copyRecoveryArtifact() {
        guard let artifact = state.recoveryArtifact else { return }
        UIPasteboard.general.string = artifact
        userIndicatorController.submitIndicator(UserIndicator(id: copyIndicatorID,
                                                              title: L10n.screenAccountAuthorityArtifactCopied,
                                                              iconName: "checkmark"))
    }

    /// Leaves the flow, dropping the prepared adoption.
    ///
    /// Its challenge is single use and its keys are unreferenced until a record carrying them is on the
    /// chain, so an abandoned preparation costs nothing and leaves nothing half-rooted: the chain either
    /// has a record at `seq 1` or it does not.
    private func leaveFlow() {
        preparedAdoption = nil
        state.recoveryArtifact = nil
        state.bindings.pin = ""
        state.bindings.hasStoredRecoveryArtifact = false
        state.errorMessage = nil
        state.phase = state.chain == nil ? .unavailable : .overview
    }

    private func message(for error: Error) -> String {
        if case AccountAuthorityServiceError.artifactUnconfirmed = error {
            return L10n.screenAccountAuthorityArtifactConfirm
        }
        return (error as? LocalizedError)?.errorDescription ?? L10n.errorUnknown
    }
}
