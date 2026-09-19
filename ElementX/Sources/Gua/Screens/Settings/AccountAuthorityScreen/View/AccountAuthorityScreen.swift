//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Compound
import SwiftUI

/// GUA FORK: the account's trusted devices, and the one transition this phone can open.
///
/// The word "authority" is not on this screen. What a reader needs is which devices can approve changes to
/// their account, and when a device that cannot yet will be able to; the chain, the records and the class
/// byte are ours to carry, not theirs to learn.
struct AccountAuthorityScreen: View {
    @Bindable var context: AccountAuthorityScreenViewModel.Context

    var body: some View {
        Form {
            switch context.viewState.phase {
            case .loading, .steppingUp, .submitting:
                loadingSection
            case .unavailable:
                unavailableSection
            case .overview:
                overviewSections
            case .enteringPin:
                pinSection
            case .artifact:
                artifactSections
            }
        }
        .compoundList()
        .navigationTitle(L10n.screenAccountAuthorityTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isInFlow {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.actionCancel) { context.send(viewAction: .cancel) }
                }
            }
        }
    }

    private var isInFlow: Bool {
        switch context.viewState.phase {
        case .enteringPin, .artifact: true
        default: false
        }
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

    private var unavailableSection: some View {
        Section {
            ListRow(label: .centeredAction(title: L10n.actionRetry, icon: \.restart),
                    kind: .button { context.send(viewAction: .retry) })
        } footer: {
            Text(L10n.screenAccountAuthorityUnavailable)
        }
    }

    // MARK: - Overview

    @ViewBuilder
    private var overviewSections: some View {
        if let pending = context.viewState.pending {
            pendingSection(pending)
        }

        switch context.viewState.chain?.state {
        case .bootstrap:
            setupSection
        case .authorityLost:
            Section {
                ListRow(label: .description(L10n.screenAccountAuthorityStateLostMessage), kind: .label)
            } header: {
                Text(L10n.screenAccountAuthorityStateLostTitle)
            }
        default:
            EmptyView()
        }

        if !context.viewState.devices.isEmpty {
            deviceSection
        }

        approvalsSection

        if let errorMessage = context.viewState.errorMessage {
            Section {
                Text(errorMessage)
                    .font(.compound.bodyMD)
                    .foregroundStyle(.compound.textCriticalPrimary)
            }
        }
    }

    private var setupSection: some View {
        Section {
            ListRow(label: .centeredAction(title: L10n.screenAccountAuthoritySetupButton, icon: \.devices),
                    kind: .button { context.send(viewAction: .startAdoption) })
                .disabled(!context.viewState.canAdopt || context.viewState.isWorking)
        } header: {
            Text(L10n.screenAccountAuthorityStateBootstrapTitle)
        } footer: {
            Text(L10n.screenAccountAuthorityStateBootstrapMessage)
        }
    }

    /// A window, said as a window: what is waiting, when it completes, and that it can still be stopped.
    private func pendingSection(_ pending: AuthorityPendingTransition) -> some View {
        Section {
            ListRow(label: .description(L10n.screenAccountAuthorityStatePendingMessage(Self.format(pending.effectiveAt))),
                    kind: .label)
        } header: {
            Text(L10n.screenAccountAuthorityStatePendingTitle)
        }
    }

    private var deviceSection: some View {
        Section {
            ForEach(context.viewState.devices) { device in
                ListRow(label: .default(title: Self.title(for: device, isThisDevice: context.viewState.isThisDevice(device)),
                                        description: Self.description(for: device),
                                        icon: \.devices),
                        kind: .label)
            }
        } header: {
            Text(L10n.screenAccountAuthorityStateRootedHeader)
        } footer: {
            if context.viewState.devices.contains(where: { $0.state == .quarantined }) {
                Text(L10n.screenAccountAuthorityDeviceQuarantinedFooter)
            }
        }
    }

    private var approvalsSection: some View {
        Section {
            ListRow(label: .default(title: L10n.screenAuthorityApprovalTitle, icon: \.check),
                    kind: .navigationLink { context.send(viewAction: .showApprovals) })
        }
    }

    // MARK: - Step-up

    private var pinSection: some View {
        Section {
            PinBubbleField(pin: $context.pin,
                           length: AccountAuthorityScreenViewState.pinLength,
                           hasError: context.viewState.errorMessage != nil)
                .onChange(of: context.pin) {
                    context.send(viewAction: .pinChanged)
                }
        } header: {
            Text(L10n.screenAccountAuthorityStepUpPinHeader)
        } footer: {
            if let errorMessage = context.viewState.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.compound.textCriticalPrimary)
            } else {
                Text(L10n.screenAccountAuthorityStepUpPinFooter)
            }
        }
    }

    // MARK: - The recovery artifact

    /// The one screen ADM-009 decision 7 makes mandatory. It says what the key is for and what holding it
    /// means, because the end state it protects against is permanent, and it does not let the adoption
    /// past it until the reader says they have stored it.
    @ViewBuilder
    private var artifactSections: some View {
        Section {
            Text(context.viewState.recoveryArtifact ?? "")
                .font(.compound.bodyLGSemibold.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            ListRow(label: .default(title: L10n.actionCopy, icon: \.copy),
                    kind: .button { context.send(viewAction: .copyRecoveryArtifact) })
        } header: {
            Text(L10n.screenAccountAuthorityArtifactTitle)
        } footer: {
            Text(L10n.screenAccountAuthorityArtifactMessage)
        }

        Section {
            ListRow(label: .plain(title: L10n.screenAccountAuthorityArtifactConfirm),
                    kind: .toggle($context.hasStoredRecoveryArtifact))
            ListRow(label: .centeredAction(title: L10n.actionContinue, icon: \.check),
                    kind: .button { context.send(viewAction: .submitAdoption) })
                .disabled(!context.viewState.canSubmitAdoption)
        } footer: {
            if let errorMessage = context.viewState.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.compound.textCriticalPrimary)
            }
        }
    }

    // MARK: - Rendering

    private static func title(for device: AuthorityDeviceSummary, isThisDevice: Bool) -> String {
        if isThisDevice {
            return L10n.screenAccountAuthorityDeviceThis
        }
        return device.label.isEmpty ? L10n.screenAccountAuthorityDeviceUnnamed : device.label
    }

    /// The device's state in the reader's words, and never a rounded one: a quarantine says when it ends,
    /// and a state this build does not know says so instead of being shown as trusted.
    private static func description(for device: AuthorityDeviceSummary) -> String {
        switch device.state {
        case .active:
            return L10n.screenAccountAuthorityDeviceActive
        case .quarantined:
            guard let until = device.quarantineUntil else {
                return L10n.screenAccountAuthorityDeviceQuarantinedUnknown
            }
            return L10n.screenAccountAuthorityDeviceQuarantined(format(until))
        case .revoked:
            return L10n.screenAccountAuthorityDeviceRevoked
        case .unknown:
            return L10n.screenAccountAuthorityDeviceUnknownState
        }
    }

    private static func format(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
