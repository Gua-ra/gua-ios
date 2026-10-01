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
            
            Text(context.viewState.canRecoverFromOtherDevice
                ? UntranslatedL10n.guaEncryptionRecoverFromOtherDeviceTitle
                : UntranslatedL10n.guaEncryptionResetRequiredTitle)
                .font(.compound.headingMDBold)
                .multilineTextAlignment(.center)
                .foregroundColor(.compound.textPrimary)
        }
    }
    
    private var footer: some View {
        Text(context.viewState.canRecoverFromOtherDevice
            ? UntranslatedL10n.guaEncryptionRecoverFromOtherDeviceMessage
            : UntranslatedL10n.guaEncryptionResetRequiredMessage)
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
    
    static let recoverViewModel: EncryptionResetScreenViewModel = {
        let clientProxy = ClientProxyMock(.init(recoveryState: .incomplete))
        clientProxy.hasDevicesToVerifyAgainstReturnValue = .success(true)
        return EncryptionResetScreenViewModel(clientProxy: clientProxy,
                                              userIndicatorController: UserIndicatorControllerMock())
    }()
    
    static var previews: some View {
        NavigationStack {
            EncryptionResetScreen(context: viewModel.context)
        }
        
        NavigationStack {
            EncryptionResetScreen(context: recoverViewModel.context)
        }
        .snapshotPreferences(expect: recoverViewModel.context.observe(\.viewState.canRecoverFromOtherDevice).map { $0 == true }.eraseToStream())
    }
}
