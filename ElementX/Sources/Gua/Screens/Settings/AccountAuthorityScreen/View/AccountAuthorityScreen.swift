//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Compound
import SwiftUI

/// GUA FORK: the account's trusted devices and the whole lifecycle this phone can drive.
///
/// The word "authority" is not on this screen, and neither is the chain, the record or the class byte:
/// those are ours to carry, not the reader's to learn. What a reader needs is which devices can approve
/// changes to their account, when a device that cannot yet will be able to, what is waiting and how to stop
/// it, and what it means when nothing is left.
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
            case .offeringThisDevice:
                ownOfferSections
            case .comparingCandidate:
                candidateComparisonSections
            case .enteringRecoveryArtifact:
                recoveryEntrySections
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
        case .enteringPin, .artifact, .offeringThisDevice, .comparingCandidate, .enteringRecoveryArtifact:
            true
        default:
            false
        }
    }

    private var loadingSection: some View {
        Section {
            HStack(spacing: 0) {
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
            lostSection
        default:
            EmptyView()
        }

        if !context.viewState.devices.isEmpty {
            deviceSection
        }

        if context.viewState.chain?.state == .rooted {
            addDeviceSection
            if !context.viewState.candidates.isEmpty {
                candidateSection
            }
            recoverySection
        }

        if context.viewState.isAlertChannelAvailable {
            alertsSection
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

    /// The terminal state of ADM-009 decision 7, said plainly and with nothing offered.
    ///
    /// There is deliberately no "set up again" button here. A second adoption authorized by login factors
    /// alone is exactly the seizure this design exists to refuse, so an account that has reached this state
    /// keeps its id, its chats and its number and does not get its authority back.
    private var lostSection: some View {
        Section {
            ListRow(label: .description(L10n.screenAccountAuthorityStateLostMessage), kind: .label)
        } header: {
            Text(L10n.screenAccountAuthorityStateLostTitle)
        }
    }

    /// A window, said as a window: what is waiting, when it completes, and who can still stop it.
    private func pendingSection(_ pending: AuthorityPendingTransition) -> some View {
        Section {
            ListRow(label: .description(Self.pendingMessage(pending)), kind: .label)
            if context.viewState.canOpposePending {
                ListRow(label: .default(title: L10n.screenAccountAuthorityStopButton, icon: \.close, role: .destructive),
                        kind: .button { context.send(viewAction: .opposePending) })
                    .disabled(context.viewState.isWorking)
            }
        } header: {
            Text(L10n.screenAccountAuthorityStatePendingTitle)
        } footer: {
            // When a device signature is needed and this phone cannot give one, the reason is said rather
            // than the button hidden with no explanation.
            if pending.type.needsADeviceToOppose, !context.viewState.canOpposePending {
                Text(L10n.screenAccountAuthorityErrorOpposeDevice)
            }
        }
    }

    private var deviceSection: some View {
        Section {
            ForEach(context.viewState.devices) { device in
                ListRow(label: .default(title: Self.title(for: device, isThisDevice: context.viewState.isThisDevice(device)),
                                        description: Self.description(for: device),
                                        icon: \.devices),
                        kind: .label)
                if context.viewState.isThisDevice(device), device.state != .revoked {
                    ListRow(label: .default(title: L10n.screenAccountAuthorityRemoveSelfButton,
                                            icon: \.close,
                                            role: .destructive),
                            kind: .button { context.send(viewAction: .revokeThisDevice) })
                        .disabled(context.viewState.isWorking)
                } else if device.state == .active || device.state == .quarantined {
                    ListRow(label: .default(title: L10n.screenAccountAuthorityRemoveButton(Self.name(for: device)),
                                            icon: \.close,
                                            role: .destructive),
                            kind: .button { context.send(viewAction: .revokeDevice(device)) })
                        .disabled(!context.viewState.canActAsAnAuthorityDevice || context.viewState.isWorking)
                }
            }
        } header: {
            Text(L10n.screenAccountAuthorityStateRootedHeader)
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                if context.viewState.devices.contains(where: { $0.state == .quarantined }) {
                    Text(L10n.screenAccountAuthorityDeviceQuarantinedFooter)
                }
                if context.viewState.thisDeviceState == .quarantined {
                    Text(L10n.screenAccountAuthorityErrorQuarantined)
                }
                if context.viewState.isInTheTwoDeviceCarveOut {
                    Text(L10n.screenAccountAuthorityRemoveTwoDevicesFooter)
                }
                Text(L10n.screenAccountAuthorityRemoveSelfFooter)
            }
        }
    }

    private var addDeviceSection: some View {
        Section {
            ListRow(label: .default(title: L10n.screenAccountAuthorityOfferThisDeviceButton, icon: \.devices),
                    kind: .button { context.send(viewAction: .offerThisDevice) })
                .disabled(context.viewState.isWorking)
        } header: {
            Text(L10n.screenAccountAuthorityAddDeviceHeader)
        } footer: {
            Text(L10n.screenAccountAuthorityAddDeviceFooter)
        }
    }

    private var candidateSection: some View {
        Section {
            ForEach(context.viewState.candidates) { candidate in
                ListRow(label: .default(title: candidate.label.isEmpty ? L10n.screenAccountAuthorityDeviceUnnamed : candidate.label,
                                        description: AuthorityFingerprint.grouped(candidate.fingerprint),
                                        icon: \.devices),
                        kind: .navigationLink { context.send(viewAction: .compareCandidate(candidate)) })
                    .disabled(!context.viewState.canActAsAnAuthorityDevice || context.viewState.isWorking)
            }
        } header: {
            Text(L10n.screenAccountAuthorityCandidateHeader)
        } footer: {
            if context.viewState.canActAsAnAuthorityDevice {
                Text(L10n.screenAccountAuthorityCandidateFooter)
            } else {
                Text(L10n.screenAccountAuthorityErrorQuarantined)
            }
        }
    }

    private var recoverySection: some View {
        Section {
            ListRow(label: .default(title: L10n.screenAccountAuthorityRecoveryButton, icon: \.key),
                    kind: .button { context.send(viewAction: .startRecovery) })
                .disabled(context.viewState.isWorking)
        } header: {
            Text(L10n.screenAccountAuthorityRecoveryHeader)
        } footer: {
            Text(L10n.screenAccountAuthorityRecoveryFooter)
        }
    }

    /// The channel every window on this screen depends on, described as what it is.
    private var alertsSection: some View {
        Section {
            ForEach(context.viewState.alerts) { alert in
                ListRow(label: .default(title: alert.deviceLabel.isEmpty ? L10n.screenAccountAuthorityDeviceUnnamed : alert.deviceLabel,
                                        description: context.viewState.isThisInstall(alert)
                                            ? L10n.screenAccountAuthorityAlertsOn
                                            : nil,
                                        icon: \.notifications),
                        kind: .label)
                ListRow(label: .default(title: L10n.screenAccountAuthorityAlertsRemoveButton, icon: \.close, role: .destructive),
                        kind: .button { context.send(viewAction: .removeAlerts(alert)) })
                    .disabled(context.viewState.isWorking)
            }
            if !context.viewState.isRegisteredForAlerts {
                ListRow(label: .default(title: L10n.screenAccountAuthorityAlertsEnableButton, icon: \.notifications),
                        kind: .button { context.send(viewAction: .enableAlerts) })
                    .disabled(context.viewState.isWorking)
            }
        } header: {
            Text(L10n.screenAccountAuthorityAlertsHeader)
        } footer: {
            Text(L10n.screenAccountAuthorityAlertsFooter)
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
    /// means, because the end state it protects against is permanent, and it does not let the record past it
    /// until the reader says they have stored it.
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
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.screenAccountAuthorityArtifactMessage)
                // A recovery mints a new key and the old one stops working, which the reader has to be told
                // or they will keep the wrong piece of paper.
                if context.viewState.artifactKind != .adoption {
                    Text(L10n.screenAccountAuthorityArtifactReplaces)
                }
            }
        }

        Section {
            ListRow(label: .plain(title: L10n.screenAccountAuthorityArtifactConfirm),
                    kind: .toggle($context.hasStoredRecoveryArtifact))
            ListRow(label: .centeredAction(title: L10n.actionContinue, icon: \.check),
                    kind: .button { context.send(viewAction: .submitArtifact) })
                .disabled(!context.viewState.canSubmitArtifact)
        } footer: {
            if let errorMessage = context.viewState.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.compound.textCriticalPrimary)
            }
        }
    }

    // MARK: - Adding a device

    /// This phone's own offer: the fingerprint it computed from its own key, for a person to read out.
    private var ownOfferSections: some View {
        Section {
            Text(AuthorityFingerprint.grouped(context.viewState.ownOffer?.fingerprint ?? ""))
                .font(.compound.headingLGBold.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 12)
        } header: {
            Text(L10n.screenAccountAuthorityOfferThisDeviceHeader)
        } footer: {
            Text(L10n.screenAccountAuthorityOfferThisDeviceFooter(Self.format(context.viewState.ownOffer?.expiresAt ?? .now)))
        }
    }

    /// The other phone's offer, and the comparison that is the whole of what binds the key to the person
    /// holding it.
    @ViewBuilder
    private var candidateComparisonSections: some View {
        Section {
            Text(AuthorityFingerprint.grouped(context.viewState.comparingCandidate?.fingerprint ?? ""))
                .font(.compound.headingLGBold.monospaced())
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 12)
        } header: {
            Text(L10n.screenAccountAuthorityCandidateCompareHeader)
        } footer: {
            Text(L10n.screenAccountAuthorityCandidateFooter)
        }

        Section {
            ListRow(label: .plain(title: L10n.screenAccountAuthorityCandidateConfirm),
                    kind: .toggle($context.hasComparedFingerprint))
            ListRow(label: .centeredAction(title: L10n.screenAccountAuthorityCandidateAddButton, icon: \.check),
                    kind: .button { context.send(viewAction: .signGrant) })
                .disabled(!context.viewState.canSignGrant)
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.screenAccountAuthorityCandidateQuarantineFooter)
                if let errorMessage = context.viewState.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.compound.textCriticalPrimary)
                }
            }
        }
    }

    // MARK: - Taking the recovery key back

    @ViewBuilder
    private var recoveryEntrySections: some View {
        Section {
            TextField(L10n.screenAccountAuthorityRecoveryFieldPlaceholder,
                      text: $context.recoveryArtifact,
                      axis: .vertical)
                .font(.compound.bodyLG.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: context.recoveryArtifact) {
                    context.send(viewAction: .recoveryArtifactChanged)
                }
            ListRow(label: .centeredAction(title: L10n.actionContinue, icon: \.check),
                    kind: .button { context.send(viewAction: .submitRecoveryArtifact) })
                .disabled(!context.viewState.canSubmitRecoveryArtifact || context.viewState.isWorking)
        } header: {
            Text(L10n.screenAccountAuthorityRecoveryHeader)
        } footer: {
            if let errorMessage = context.viewState.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.compound.textCriticalPrimary)
            } else {
                Text(L10n.screenAccountAuthorityRecoveryFooter)
            }
        }

        Section {
            ListRow(label: .default(title: L10n.screenAccountAuthorityRecoveryNoKeyButton, icon: \.help),
                    kind: .button { context.send(viewAction: .startRecoveryThroughAccountRecovery) })
                .disabled(context.viewState.isWorking)
        } footer: {
            Text(L10n.screenAccountAuthorityRecoveryNoKeyFooter)
        }
    }

    // MARK: - Rendering

    private static func title(for device: AuthorityDeviceSummary, isThisDevice: Bool) -> String {
        if isThisDevice {
            return L10n.screenAccountAuthorityDeviceThis
        }
        return name(for: device)
    }

    private static func name(for device: AuthorityDeviceSummary) -> String {
        device.label.isEmpty ? L10n.screenAccountAuthorityDeviceUnnamed : device.label
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

    /// What is waiting, in the reader's words, by type. A window whose type this build does not know is
    /// still shown with its date rather than dropped, because the date is the part that matters.
    private static func pendingMessage(_ pending: AuthorityPendingTransition) -> String {
        let when = format(pending.effectiveAt)
        switch pending.type {
        case .adoptRoot:
            return L10n.screenAccountAuthorityStatePendingMessage(when)
        case .deviceGrant:
            return L10n.screenAccountAuthorityStatePendingGrant(when)
        case .deviceRevoke:
            return L10n.screenAccountAuthorityStatePendingRevoke(when)
        case .authorityRecovery:
            return L10n.screenAccountAuthorityStatePendingRecovery(when)
        case .unknown:
            return L10n.screenAccountAuthorityStatePendingUnknown(when)
        }
    }

    private static func format(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
