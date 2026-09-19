//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Combine
import SwiftUI

typealias AuthorityApprovalScreenViewModelType = StateStoreViewModelV2<AuthorityApprovalScreenViewState, AuthorityApprovalScreenViewAction>

/// The signature a browser session cannot produce for itself (ADM-009 decision 6).
///
/// A browser login grants account access and never authority. What reaches this screen is a pending
/// approval carrying an action digest and a challenge; what leaves it is one signature by this device's
/// authority key. The browser never learns a key and never proxies one, so the page that started the
/// approval can reach it and not the signature.
class AuthorityApprovalScreenViewModel: AuthorityApprovalScreenViewModelType, AuthorityApprovalScreenViewModelProtocol {
    private let authorityService: AccountAuthorityServiceProtocol
    private let clientProxy: ClientProxyProtocol
    private let userIndicatorController: UserIndicatorControllerProtocol

    /// Read alongside the approvals, because the preimage covers the account's own 34 id bytes and the
    /// signature is made with the key the chain names for this device.
    private var chain: AuthorityChainState?

    private let actionsSubject: PassthroughSubject<AuthorityApprovalScreenViewModelAction, Never> = .init()
    var actionsPublisher: AnyPublisher<AuthorityApprovalScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(authorityService: AccountAuthorityServiceProtocol,
         clientProxy: ClientProxyProtocol,
         userIndicatorController: UserIndicatorControllerProtocol) {
        self.authorityService = authorityService
        self.clientProxy = clientProxy
        self.userIndicatorController = userIndicatorController

        super.init(initialViewState: AuthorityApprovalScreenViewState())

        Task { await load() }
    }

    override func process(viewAction: AuthorityApprovalScreenViewAction) {
        switch viewAction {
        case .retry:
            Task { await load() }
        case .sign:
            Task { await sign() }
        case .close:
            actionsSubject.send(.close)
        }
    }

    private func load() async {
        guard let accessToken = clientProxy.accessToken else {
            state.phase = .unavailable
            return
        }
        state.phase = .loading
        state.errorMessage = nil
        do {
            let chain = try await authorityService.state(accessToken: accessToken)
            self.chain = chain
            // Only a device the chain names can sign, and a quarantined one may not: it may not sign a
            // grant, a revocation or an authority-sensitive approval while its own window runs.
            guard let deviceKey = authorityService.thisDeviceKey(accountID: chain.accountID),
                  chain.unquarantinedActiveDevices.contains(where: { $0.deviceKey == deviceKey }) else {
                state.phase = .unavailable
                state.errorMessage = L10n.screenAuthorityApprovalNotAnAuthorityDevice
                return
            }

            let approvals = try await authorityService.liveApprovals(accessToken: accessToken)
            switch approvals.count {
            case 0:
                state.approval = nil
                state.phase = .empty
            case 1:
                let approval = approvals[0]
                state.approval = approval
                state.action = AuthorityApprovalAction(actionID: approval.action)
                state.phase = .approval
                if !state.action.isSignable {
                    state.errorMessage = L10n.screenAuthorityApprovalUnknownAction
                }
            default:
                // Refusing to present any of them is the rule, not a convenience: with two codes live the
                // reader can match the wrong screen, and matching is the whole of what the code is for.
                state.approval = nil
                state.phase = .tooManyLive
            }
        } catch {
            MXLog.error("Failed reading the live authority approvals: \(error)")
            state.phase = .unavailable
            state.errorMessage = (error as? LocalizedError)?.errorDescription ?? L10n.errorUnknown
        }
    }

    private func sign() async {
        guard state.canSign,
              let approval = state.approval,
              let chain,
              let accessToken = clientProxy.accessToken else { return }

        state.phase = .signing
        do {
            try await authorityService.signApproval(accessToken: accessToken, approval: approval, state: chain)
            state.phase = .signed
            userIndicatorController.submitIndicator(UserIndicator(title: L10n.screenAuthorityApprovalSigned,
                                                                  iconName: "checkmark"))
        } catch {
            MXLog.error("Failed signing the authority approval: \(error)")
            // The approval is burned on refusal as well as on acceptance, so there is nothing to retry
            // here: the other screen has to ask again. Re-reading says so honestly, and the refusal is
            // restated afterwards because the re-read clears whatever was on screen.
            let message = (error as? LocalizedError)?.errorDescription ?? L10n.errorUnknown
            await load()
            state.errorMessage = message
        }
    }
}
