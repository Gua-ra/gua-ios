//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct EncryptionResetScreen: View {
    @Bindable var context: EncryptionResetScreenViewModel.Context
    
    var body: some View {
        FullscreenDialog {
            mainContent
        } bottomContent: {
            VStack(spacing: 16) {
                // GUA FORK: offered only when another device of this account holds the keys. It
                // brings the messages here without resetting anything; otherwise the reset is
                // the only way forward and the sole option shown.
                if context.viewState.canRecoverFromOtherDevice {
                    Button(UntranslatedL10n.guaEncryptionRecoverFromOtherDeviceAction) {
                        context.send(viewAction: .recoverFromOtherDevice)
                    }
                    .disabled(context.viewState.isResetting)
                    .buttonStyle(.compound(.primary))
                }

                Button(UntranslatedL10n.guaEncryptionResetRequiredAction, role: .destructive) {
                    context.send(viewAction: .reset)
                }
                .disabled(context.viewState.isResetting)
                .buttonStyle(.compound(context.viewState.canRecoverFromOtherDevice ? .secondary : .primary))
                .accessibilityIdentifier(A11yIdentifiers.encryptionResetScreen.continueReset)
            }
        }
        .background()
        .backgroundStyle(.compound.bgCanvasDefault)
        .interactiveDismissDisabled()
        .toolbar { toolbar }
        .toolbar(.visible, for: .navigationBar)
        .alert(item: $context.alertInfo)
    }
    
    /// The main content of the screen that is shown inside the scroll view.
    private var mainContent: some View {
        VStack(spacing: 24) {
            header
            footer
        }
    }
    
    private var header: some View {
        VStack(spacing: 8) {
            BigIcon(icon: \.errorSolid, style: .alertSolid)
                .padding(.bottom, 8)
            
            // GUA FORK: this screen is only reached once a reset is genuinely required, so
            // it names the loss plainly instead of leading with jargon about identities.
            Text(UntranslatedL10n.guaEncryptionResetRequiredTitle)
                .font(.compound.headingMDBold)
                .multilineTextAlignment(.center)
                .foregroundColor(.compound.textPrimary)
        }
    }
    
    private var footer: some View {
        Text(UntranslatedL10n.guaEncryptionResetRequiredMessage)
            .font(.compound.bodyMD)
            .multilineTextAlignment(.center)
            .foregroundColor(.compound.textSecondary)
    }
    
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(L10n.actionCancel) {
                context.send(viewAction: .cancel)
            }
        }
    }
}

// MARK: - Previews

struct EncryptionResetScreen_Previews: PreviewProvider, TestablePreview {
    static let viewModel = EncryptionResetScreenViewModel(clientProxy: ClientProxyMock(.init()),
                                                          userIndicatorController: UserIndicatorControllerMock())
    static var previews: some View {
        NavigationStack {
            EncryptionResetScreen(context: viewModel.context)
        }
    }
}
