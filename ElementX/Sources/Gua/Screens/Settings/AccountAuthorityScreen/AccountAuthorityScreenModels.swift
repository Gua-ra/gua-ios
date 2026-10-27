//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation

enum AccountAuthorityScreenViewModelAction {
    case close
    case showApprovals
}

/// A record that mints a recovery key always passes through `artifact` before `submitting`.
enum AccountAuthorityScreenPhase: Equatable {
    case loading
    case overview
    case unavailable
    case steppingUp
    case enteringPin
    case artifact
    case submitting
    case offeringThisDevice
    case comparingCandidate
    case enteringRecoveryArtifact
}

enum AccountAuthorityScreenOperation: Equatable {
    case adoption
    case grant(AuthorityCandidate)
    case revokeAnother(deviceKey: String, label: String)
    case revokeThisDevice(deviceKey: String)
    case recoveryWithArtifact(String)
    case recoveryThroughAccountRecovery
    case removeAlerts(installationID: String)
    case oppose(AuthorityPendingTransition)

    var webStepUpPurpose: AuthorityPurpose? {
        switch self {
        case .adoption: .adopt
        case .grant: .grant
        case .revokeAnother, .revokeThisDevice: .revoke
        case .recoveryWithArtifact, .recoveryThroughAccountRecovery: .recover
        case .removeAlerts, .oppose: nil
        }
    }
}

struct AccountAuthorityScreenViewState: BindableState {
    static let pinLength = 6

    var phase: AccountAuthorityScreenPhase = .loading
    var chain: AuthorityChainState?
    var thisDeviceKey: String?
    var candidates: [AuthorityCandidate] = []
    var ownOffer: AuthorityCandidate?
    var comparingCandidate: AuthorityCandidate?
    var alerts: [SecurityNotificationSummary] = []
    var thisInstallationID: String?
    var isAlertChannelAvailable = false
    var recoveryArtifact: String?
    var artifactKind: PreparedAuthorityRecord.Kind = .adoption
    var errorMessage: String?
    var isUnavailablePermanently = false
    var bindings = AccountAuthorityScreenViewStateBindings()

    var isWorking: Bool {
        phase == .steppingUp || phase == .submitting
    }

    var canAdopt: Bool {
        chain?.canAdopt ?? false
    }

    var pending: AuthorityPendingTransition? {
        chain?.pending
    }

    var canOpposePending: Bool {
        guard let pending else { return false }
        guard pending.type.needsADeviceToOppose else { return true }
        return thisDeviceState == .active
    }

    var thisDeviceState: AuthorityDeviceState? {
        guard let thisDeviceKey else { return nil }
        return chain?.devices.first { $0.deviceKey == thisDeviceKey }?.state
    }

    var canActAsAnAuthorityDevice: Bool {
        thisDeviceState == .active && chain?.pending == nil
    }

    var devices: [AuthorityDeviceSummary] {
        let devices = (chain?.devices ?? []).sorted { $0.grantedSeq < $1.grantedSeq }
        guard let thisDeviceKey else { return devices }
        return devices.filter { $0.deviceKey == thisDeviceKey } + devices.filter { $0.deviceKey != thisDeviceKey }
    }

    var activeDevices: [AuthorityDeviceSummary] {
        chain?.unquarantinedActiveDevices ?? []
    }

    /// With exactly two active devices, the device being removed may object.
    var isInTheTwoDeviceCarveOut: Bool {
        activeDevices.count == 2
    }

    var isAuthorityLost: Bool {
        chain?.state == .authorityLost
    }

    func isThisDevice(_ device: AuthorityDeviceSummary) -> Bool {
        device.deviceKey == thisDeviceKey
    }

    func isThisInstall(_ alert: SecurityNotificationSummary) -> Bool {
        alert.installationID == thisInstallationID
    }

    var isRegisteredForAlerts: Bool {
        guard let thisInstallationID else { return false }
        return alerts.contains { $0.installationID == thisInstallationID }
    }

    var canSubmitArtifact: Bool {
        phase == .artifact && bindings.hasStoredRecoveryArtifact
    }

    var canSignGrant: Bool {
        phase == .comparingCandidate && bindings.hasComparedFingerprint
    }

    var canSubmitPin: Bool {
        phase == .enteringPin && bindings.pin.count == Self.pinLength && bindings.pin.allSatisfy(\.isNumber)
    }

    var canRecoverThroughAccountRecovery: Bool {
        chain?.canRecoverThroughAccountRecovery ?? false
    }

    var canSubmitRecoveryArtifact: Bool {
        phase == .enteringRecoveryArtifact && AuthorityRecoveryArtifact.looksComplete(bindings.recoveryArtifact)
    }
}

struct AccountAuthorityScreenViewStateBindings {
    var pin = ""
    var hasStoredRecoveryArtifact = false
    var hasComparedFingerprint = false
    var recoveryArtifact = ""
}

enum AccountAuthorityScreenViewAction {
    case retry
    case startAdoption
    case pinChanged
    case pinSubmitted
    case copyRecoveryArtifact
    case submitArtifact
    case cancel
    case showApprovals
    case opposePending
    case offerThisDevice
    case compareCandidate(AuthorityCandidate)
    case signGrant
    case revokeDevice(AuthorityDeviceSummary)
    case revokeThisDevice
    case startRecovery
    case recoveryArtifactChanged
    case submitRecoveryArtifact
    case startRecoveryThroughAccountRecovery
    case enableAlerts
    case removeAlerts(SecurityNotificationSummary)
}
