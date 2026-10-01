//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Compound
import SwiftUI

struct AuthorityApprovalScreen: View {
    @Bindable var context: AuthorityApprovalScreenViewModel.Context

    var body: some View {
        Form {
            switch context.viewState.phase {
            case .loading, .signing:
                loadingSection
            case .empty:
                messageSection(L10n.screenAuthorityApprovalEmpty)
            case .tooManyLive:
                messageSection(L10n.screenAuthorityApprovalMultiple)
            case .signed:
                messageSection(L10n.screenAuthorityApprovalSigned)
            case .unavailable:
                unavailableSection
            case .approval:
                approvalSections
            }
        }
        .compoundList()
        .navigationTitle(L10n.screenAuthorityApprovalTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var loadingSection: some View {
        Section {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding(.vertical, 24)
        }
    }

    private func messageSection(_ message: String) -> some View {
        Section {
            ListRow(label: .description(message), kind: .label)
        }
    }

    private var unavailableSection: some View {
        Section {
            ListRow(label: .centeredAction(title: L10n.actionRetry, icon: \.restart),
                    kind: .button { context.send(viewAction: .retry) })
        } footer: {
            Text(context.viewState.errorMessage ?? L10n.errorUnknown)
        }
    }

    @ViewBuilder
    private var approvalSections: some View {
        Section {
            Text(context.viewState.spacedCode)
                .font(.compound.headingLGBold.monospaced())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        } header: {
            Text(L10n.screenAuthorityApprovalCodeHeader)
        }

        Section {
            ListRow(label: .description(context.viewState.action.sentence ?? L10n.screenAuthorityApprovalUnknownAction),
                    kind: .label)
        } header: {
            Text(L10n.screenAuthorityApprovalActionHeader)
        }

        Section {
            ListRow(label: .centeredAction(title: L10n.screenAuthorityApprovalSignButton, icon: \.check),
                    kind: .button { context.send(viewAction: .sign) })
                .disabled(!context.viewState.canSign)
        } footer: {
            if let errorMessage = context.viewState.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.compound.textCriticalPrimary)
            }
        }
    }
}

// MARK: - Previews

struct AuthorityApprovalScreen_Previews: PreviewProvider, TestablePreview {
    static let viewModel = makeViewModel(approvals: [approval(actionID: "authority.device.grant")])

    static let undescribableViewModel = makeViewModel(approvals: [approval(actionID: "something.this.build.cannot.name")])

    static let tooManyViewModel = makeViewModel(approvals: [approval(actionID: "authority.device.grant"),
                                                            approval(actionID: "authority.device.revoke", id: "second", code: "M4XQ")])

    static var previews: some View {
        NavigationStack {
            AuthorityApprovalScreen(context: viewModel.context)
        }
        .snapshotPreferences(expect: viewModel.context.observe(\.viewState.phase).map { $0 == .approval }.eraseToStream())
        .previewDisplayName("One approval")

        NavigationStack {
            AuthorityApprovalScreen(context: undescribableViewModel.context)
        }
        .snapshotPreferences(expect: undescribableViewModel.context.observe(\.viewState.phase).map { $0 == .approval }.eraseToStream())
        .previewDisplayName("Unnameable action")

        NavigationStack {
            AuthorityApprovalScreen(context: tooManyViewModel.context)
        }
        .snapshotPreferences(expect: tooManyViewModel.context.observe(\.viewState.phase).map { $0 == .tooManyLive }.eraseToStream())
        .previewDisplayName("More than one live")
    }

    // MARK: - Fixtures

    static func approval(actionID: String, id: String = "an-approval", code: String = "AB7K") -> AuthorityApproval {
        AuthorityApproval(approvalID: id,
                          code: code,
                          action: actionID,
                          actionDigest: "a-digest",
                          challenge: "a-challenge",
                          expiresAt: Date(timeIntervalSince1970: 1_767_323_445))
    }

    static func makeViewModel(approvals: [AuthorityApproval]) -> AuthorityApprovalScreenViewModel {
        let clientProxy = ClientProxyMock(.init())
        clientProxy.accessToken = "preview-token"
        let chain = AuthorityChainState(accountID: AccountAuthorityServiceMock.accountID,
                                        accountClass: .bootstrap,
                                        state: .rooted,
                                        headSeq: 2,
                                        headHash: String(repeating: "ab", count: 32),
                                        devices: [AuthorityDeviceSummary(deviceKey: "this-device",
                                                                         label: "iPhone",
                                                                         state: .active,
                                                                         quarantineUntil: nil,
                                                                         grantedSeq: 1)],
                                        pending: nil)
        let authorityService = AccountAuthorityServiceMock(chain: chain,
                                                           approvals: approvals,
                                                           installationID: "this-install",
                                                           deviceKey: "this-device")
        return AuthorityApprovalScreenViewModel(authorityService: authorityService,
                                                clientProxy: clientProxy,
                                                userIndicatorController: UserIndicatorControllerMock())
    }
}
