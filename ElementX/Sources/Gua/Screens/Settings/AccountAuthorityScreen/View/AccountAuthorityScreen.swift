//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Compound
import SwiftUI

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
            if !context.viewState.isUnavailablePermanently {
                ListRow(label: .centeredAction(title: L10n.actionRetry, icon: \.restart),
                        kind: .button { context.send(viewAction: .retry) })
            }
        } footer: {
            Text(context.viewState.isUnavailablePermanently
                ? L10n.screenAccountAuthorityErrorNoAccount
                : L10n.screenAccountAuthorityUnavailable)
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

    /// Deliberately offers no second adoption.
    private var lostSection: some View {
        Section {
            ListRow(label: .description(L10n.screenAccountAuthorityStateLostMessage), kind: .label)
        } header: {
            Text(L10n.screenAccountAuthorityStateLostTitle)
        }
    }

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

        if context.viewState.canRecoverThroughAccountRecovery {
            Section {
                ListRow(label: .default(title: L10n.screenAccountAuthorityRecoveryNoKeyButton, icon: \.help),
                        kind: .button { context.send(viewAction: .startRecoveryThroughAccountRecovery) })
                    .disabled(context.viewState.isWorking)
            } footer: {
                Text(L10n.screenAccountAuthorityRecoveryNoKeyFooter)
            }
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

// MARK: - Previews

struct AccountAuthorityScreen_Previews: PreviewProvider, TestablePreview {
    static let viewModel = makeViewModel(chain: rootedChain(devices: [thisDevice, quarantinedDevice]),
                                         candidates: [AccountAuthorityServiceMock.candidate],
                                         approvals: [approval],
                                         alerts: [thisInstallAlert, otherInstallAlert])

    static let alertsViewModel = makeViewModel(chain: rootedChain(devices: []),
                                               alerts: [thisInstallAlert, otherInstallAlert])

    static let genesisViewModel = makeViewModel(chain: rootedChain(accountClass: .genesis, devices: [thisDevice]))

    static let lostViewModel = makeViewModel(chain: AuthorityChainState(accountID: accountID,
                                                                        accountClass: .bootstrap,
                                                                        state: .authorityLost,
                                                                        headSeq: 4,
                                                                        headHash: headHash,
                                                                        devices: [],
                                                                        pending: nil))

    static var previews: some View {
        NavigationStack {
            AccountAuthorityScreen(context: viewModel.context)
        }
        .snapshotPreferences(expect: viewModel.context.observe(\.viewState.phase).map { $0 == .overview }.eraseToStream())
        .previewDisplayName("Rooted")

        NavigationStack {
            AccountAuthorityScreen(context: alertsViewModel.context)
        }
        .snapshotPreferences(expect: alertsViewModel.context.observe(\.viewState.phase).map { $0 == .overview }.eraseToStream())
        .previewDisplayName("Security alerts")

        NavigationStack {
            AccountAuthorityScreen(context: genesisViewModel.context)
        }
        .snapshotPreferences(expect: genesisViewModel.context.observe(\.viewState.phase).map { $0 == .overview }.eraseToStream())
        .previewDisplayName("Genesis account")

        NavigationStack {
            AccountAuthorityScreen(context: lostViewModel.context)
        }
        .snapshotPreferences(expect: lostViewModel.context.observe(\.viewState.phase).map { $0 == .overview }.eraseToStream())
        .previewDisplayName("Authority lost")
    }

    // MARK: - Fixtures

    static let accountID = AccountAuthorityServiceMock.accountID

    static let headHash = String(repeating: "ab", count: 32)

    static let thisDevice = AuthorityDeviceSummary(deviceKey: "this-device",
                                                   label: "iPhone",
                                                   state: .active,
                                                   quarantineUntil: nil,
                                                   grantedSeq: 1)

    /// No end date: a rendered date would depend on the recording machine's time zone.
    static let quarantinedDevice = AuthorityDeviceSummary(deviceKey: "other-device",
                                                          label: "iPad",
                                                          state: .quarantined,
                                                          quarantineUntil: nil,
                                                          grantedSeq: 2)

    static let approval = AuthorityApproval(approvalID: "an-approval",
                                            code: "AB7K",
                                            action: "authority.device.grant",
                                            actionDigest: "a-digest",
                                            challenge: "a-challenge",
                                            expiresAt: Date(timeIntervalSince1970: 1_767_323_445))

    static let thisInstallAlert = SecurityNotificationSummary(installationID: "this-install",
                                                              platform: "APNS",
                                                              deviceLabel: "iPhone",
                                                              tokenFingerprint: "9f2a",
                                                              isBoundToAnAuthorityDevice: true,
                                                              lastSeenAt: Date(timeIntervalSince1970: 1_767_322_845))

    static let otherInstallAlert = SecurityNotificationSummary(installationID: "other-install",
                                                               platform: "APNS",
                                                               deviceLabel: "iPad",
                                                               tokenFingerprint: "4c1d",
                                                               isBoundToAnAuthorityDevice: false,
                                                               lastSeenAt: Date(timeIntervalSince1970: 1_767_322_845))

    static func rootedChain(accountClass: AuthorityAccountClass = .bootstrap,
                            devices: [AuthorityDeviceSummary]) -> AuthorityChainState {
        AuthorityChainState(accountID: accountID,
                            accountClass: accountClass,
                            state: .rooted,
                            headSeq: 2,
                            headHash: headHash,
                            devices: devices,
                            pending: nil)
    }

    static func makeViewModel(chain: AuthorityChainState,
                              candidates: [AuthorityCandidate] = [],
                              approvals: [AuthorityApproval] = [],
                              alerts: [SecurityNotificationSummary] = []) -> AccountAuthorityScreenViewModel {
        let clientProxy = ClientProxyMock(.init())
        clientProxy.accessToken = "preview-token"
        let authorityService = AccountAuthorityServiceMock(chain: chain,
                                                           candidateList: candidates,
                                                           approvals: approvals,
                                                           alerts: alerts,
                                                           installationID: "this-install",
                                                           deviceKey: "this-device")
        let identityServiceClient = IdentityServiceClientMock(status: .init(hasPin: true,
                                                                            passkeyRegistered: false,
                                                                            preferredFactor: .pin,
                                                                            phoneChangeStepUpFactors: [.pin],
                                                                            pinStepUpHoldRemainingSeconds: 0))
        return AccountAuthorityScreenViewModel(authorityService: authorityService,
                                               identityServiceClient: identityServiceClient,
                                               clientProxy: clientProxy,
                                               userIndicatorController: UserIndicatorControllerMock())
    }
}
