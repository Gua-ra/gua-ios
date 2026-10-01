//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Combine
import SwiftUI

typealias AuthorityApprovalScreenViewModelType = StateStoreViewModelV2<AuthorityApprovalScreenViewState, AuthorityApprovalScreenViewAction>

class AuthorityApprovalScreenViewModel: AuthorityApprovalScreenViewModelType, AuthorityApprovalScreenViewModelProtocol {
    private let authorityService: AccountAuthorityServiceProtocol
    private let clientProxy: ClientProxyProtocol
    private let userIndicatorController: UserIndicatorControllerProtocol

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
            // The approval is burned on refusal too, so there is nothing to retry.
            let message = (error as? LocalizedError)?.errorDescription ?? L10n.errorUnknown
            await load()
            state.errorMessage = message
        }
    }
}
