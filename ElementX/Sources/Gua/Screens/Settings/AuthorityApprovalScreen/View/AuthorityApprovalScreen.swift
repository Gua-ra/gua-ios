//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Compound
import SwiftUI

/// GUA FORK: approving, from a device that holds the account's authority, an action something else asked
/// for.
///
/// Two things are on this screen and both have to be: the four-character code, so the reader can see they
/// are answering the request in front of them, and what the request would do, in words. A page that
/// started an approval nobody wanted reaches the first screen and not this one.
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
