//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation

enum AccountAuthorityScreenViewModelAction {
    case close
    /// The user asked to look at what a browser session is waiting for. The coordinator pushes it; the
    /// view model cannot.
    case showApprovals
}

/// Where the screen is in the flows it owns.
///
/// ``artifact`` is the step ADM-009 decision 7 makes mandatory: a **new** recovery authority key is shown
/// once and the record is refused until the user says they stored it. Both records that mint one, the
/// adoption and the recovery, pass through it, and there is deliberately no path from ``steppingUp`` or
/// ``enteringPin`` to ``submitting`` that skips it.
enum AccountAuthorityScreenPhase: Equatable {
    case loading
    /// The chain was read. What is shown depends on the state it reported, not on this phase.
    case overview
    /// The chain could not be read. Not the same as "this account has nothing": the screen says so and
    /// offers a retry rather than inviting a setup it cannot see the need for.
    case unavailable
    /// A passkey sheet is up, or a record is being built.
    case steppingUp
    case enteringPin
    case artifact
    case submitting
    /// This phone's own key has been offered, and its fingerprint is on screen to be read out.
    case offeringThisDevice
    /// Another device's key is on screen, waiting for the human comparison before a grant is signed.
    case comparingCandidate
    /// The recovery key is being typed or pasted back in.
    case enteringRecoveryArtifact
}

/// What a step-up, once obtained, is going to authorize.
///
/// Held as a value rather than as a flag per flow, so the factor ceremony is written once: every
/// transition on this screen asks for the same two factors in the same order, and none of them can drift
/// into asking for a third.
enum AccountAuthorityScreenOperation: Equatable {
    case adoption
    case grant(AuthorityCandidate)
    case revokeAnother(deviceKey: String, label: String)
    case revokeThisDevice(deviceKey: String)
    case recoveryWithArtifact(String)
    case recoveryThroughAccountRecovery
    case removeAlerts(installationID: String)
    /// Objecting to what is pending, a second time. The first objection presents no factor and never
    /// reaches this: it is here because the server asks for one from the second onward, and an objection
    /// that dead-ends on that refusal is a veto the owner cannot cast.
    case oppose(AuthorityPendingTransition)

    /// The purpose a web step-up for this transition is scoped to, or `nil` when the sheet cannot confirm
    /// it at all.
    ///
    /// It is the purpose the challenge is minted for, stated once here so the sheet a person is sent to and
    /// the transition it authorizes cannot name different things. Two operations on this screen have no
    /// purpose here. Turning off security alerts: its factor is not one the chain's sheet records, and what
    /// it really turns on is a signature by the key the row itself names. Objecting: `OPPOSE` is one of the
    /// purposes that ask for no factor in their own right, so the deployment refuses a sheet for it, and the
    /// factor a second objection presents is a passkey on this device or the account's PIN.
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
    /// What the server reports. `nil` means it has not been read, which is never rendered as "empty".
    var chain: AuthorityChainState?
    /// This device's own authority key, base64url, when it holds one for this account. It is how the
    /// list can say which row is the phone in the reader's hand.
    var thisDeviceKey: String?
    /// The keys other devices of this account have offered for a grant.
    var candidates: [AuthorityCandidate] = []
    /// This phone's own offer, while it is on screen waiting to be confirmed elsewhere.
    var ownOffer: AuthorityCandidate?
    /// The candidate whose fingerprint is being compared right now.
    var comparingCandidate: AuthorityCandidate?
    /// The security-notification registrations of this account, and which one is this install.
    var alerts: [SecurityNotificationSummary] = []
    var thisInstallationID: String?
    /// Whether this deployment has the channel at all. It has its own off-by-default flag on the server, so
    /// an empty list and a channel that is not there are different answers and only one of them is worth
    /// offering to turn on.
    var isAlertChannelAvailable = false
    /// The recovery key, only while ``AccountAuthorityScreenPhase/artifact`` is on screen.
    var recoveryArtifact: String?
    /// Which record the artifact on screen belongs to, so the copy can say what happens next.
    var artifactKind: PreparedAuthorityRecord.Kind = .adoption
    var errorMessage: String?
    /// Whether ``AccountAuthorityScreenPhase/unavailable`` is a permanent answer rather than a failed read.
    ///
    /// "This deployment does not run the chain" and "this account has no account object" are answers, not
    /// errors, and retrying either one can never succeed. Offering a retry there points the owner at a
    /// button that does nothing, on the one screen the whole feature is reached from.
    var isUnavailablePermanently = false
    var bindings = AccountAuthorityScreenViewStateBindings()

    var isWorking: Bool {
        phase == .steppingUp || phase == .submitting
    }

    /// Whether this account can be rooted on this phone at all.
    var canAdopt: Bool {
        chain?.canAdopt ?? false
    }

    /// The pending transition, when one is inside its window.
    var pending: AuthorityPendingTransition? {
        chain?.pending
    }

    /// Whether this phone can object to what is pending.
    ///
    /// An adoption can be opposed from any signed-in session, so the button is offered whatever this phone
    /// holds. Everything else needs a signature from a key the chain has active, so the button is offered
    /// only when this phone holds one and is not itself quarantined: showing it otherwise would be an offer
    /// the server refuses, on the one screen where a refusal costs the owner the window.
    var canOpposePending: Bool {
        guard let pending else { return false }
        guard pending.type.needsADeviceToOppose else { return true }
        return thisDeviceState == .active
    }

    /// What the chain says about the phone in the reader's hand.
    var thisDeviceState: AuthorityDeviceState? {
        guard let thisDeviceKey else { return nil }
        return chain?.devices.first { $0.deviceKey == thisDeviceKey }?.state
    }

    /// Whether this phone may sign a grant or a revocation today.
    ///
    /// A quarantined device may not, and says so rather than offering the action: its own grant is still
    /// inside its window, and it does not count toward the device a revocation must leave behind either.
    var canActAsAnAuthorityDevice: Bool {
        thisDeviceState == .active && chain?.pending == nil
    }

    /// Devices in the order the chain granted them, which is the only order the chain fixes. The device
    /// in the reader's hand is lifted to the top, because that is the row they are looking for.
    var devices: [AuthorityDeviceSummary] {
        let devices = (chain?.devices ?? []).sorted { $0.grantedSeq < $1.grantedSeq }
        guard let thisDeviceKey else { return devices }
        return devices.filter { $0.deviceKey == thisDeviceKey } + devices.filter { $0.deviceKey != thisDeviceKey }
    }

    /// Devices the chain counts as this account's authority today. A quarantined one is deliberately not
    /// among them.
    var activeDevices: [AuthorityDeviceSummary] {
        chain?.unquarantinedActiveDevices ?? []
    }

    /// The two-device carve-out of ADM-009 decision 5, which the screen states rather than hides.
    ///
    /// On an account with two active devices, removing either would leave the signer alone, so the named
    /// device is allowed to object. A standoff between two devices is a worse outcome for nobody; an
    /// eviction the owner is forbidden to object to is a takeover.
    var isInTheTwoDeviceCarveOut: Bool {
        activeDevices.count == 2
    }

    /// Whether the terminal state of ADM-009 decision 7 has been reached: rooted, no device left, no
    /// recovery key. The screen says so plainly and offers no second adoption.
    var isAuthorityLost: Bool {
        chain?.state == .authorityLost
    }

    func isThisDevice(_ device: AuthorityDeviceSummary) -> Bool {
        device.deviceKey == thisDeviceKey
    }

    /// Whether a row is the phone in the reader's hand, which the list says so that a stranger among them
    /// can be recognised. It decides a label and nothing else: what removing a row costs is the same for
    /// this one as for any other.
    func isThisInstall(_ alert: SecurityNotificationSummary) -> Bool {
        alert.installationID == thisInstallationID
    }

    /// Whether this install already has somewhere for a warning to arrive.
    var isRegisteredForAlerts: Bool {
        guard let thisInstallationID else { return false }
        return alerts.contains { $0.installationID == thisInstallationID }
    }

    /// Continue is off until the confirmation is on. The server refuses an unconfirmed adoption too, so
    /// this is the screen agreeing with the rule rather than being the only thing holding it.
    var canSubmitArtifact: Bool {
        phase == .artifact && bindings.hasStoredRecoveryArtifact
    }

    /// A grant is off until the reader says the two fingerprints matched. The comparison is the only thing
    /// binding the offered key to the person holding the other phone.
    var canSignGrant: Bool {
        phase == .comparingCandidate && bindings.hasComparedFingerprint
    }

    var canSubmitPin: Bool {
        phase == .enteringPin && bindings.pin.count == Self.pinLength && bindings.pin.allSatisfy(\.isNumber)
    }

    /// Whether the weaker recovery route may be offered: `AuthorityRecovery` with authorization `0x02`.
    ///
    /// ADM-009 decision 3 rule 3 refuses it outright on a class `0x01` account, so on one the button's only
    /// outcome is a refusal, after a challenge has been minted and a step-up spent. gua-android has withheld
    /// the row on that condition since it was written and this is the same gate, read from the chain rather
    /// than from a local flag so the offer follows what the server accepts.
    var canRecoverThroughAccountRecovery: Bool {
        chain?.canRecoverThroughAccountRecovery ?? false
    }

    /// Whether what has been typed could be a recovery key at all. The service refuses malformed material
    /// before submission; this is the button agreeing with it.
    var canSubmitRecoveryArtifact: Bool {
        phase == .enteringRecoveryArtifact && AuthorityRecoveryArtifact.looksComplete(bindings.recoveryArtifact)
    }
}

struct AccountAuthorityScreenViewStateBindings {
    var pin = ""
    /// The user's own statement that they wrote the recovery key down. Nothing else sets it.
    var hasStoredRecoveryArtifact = false
    /// The user's own statement that the two fingerprints matched. Nothing else sets it.
    var hasComparedFingerprint = false
    var recoveryArtifact = ""
}

enum AccountAuthorityScreenViewAction {
    /// Re-read the chain.
    case retry
    /// Start rooting this account on this phone.
    case startAdoption
    case pinChanged
    case pinSubmitted
    /// Put the recovery key on the clipboard. It is the key itself, so this is the one copy action in
    /// the app that is worth a confirmation the user can see.
    case copyRecoveryArtifact
    /// The artifact is stored and the record may go ahead.
    case submitArtifact
    case cancel
    case showApprovals
    /// Object to what is pending, by whichever route its type permits.
    case opposePending
    /// Offer this phone's own key so a trusted device can add it.
    case offerThisDevice
    /// Look at one offered key and compare its fingerprint.
    case compareCandidate(AuthorityCandidate)
    /// Sign the grant for the candidate being compared.
    case signGrant
    case revokeDevice(AuthorityDeviceSummary)
    case revokeThisDevice
    /// Open the field that takes the recovery key back.
    case startRecovery
    case recoveryArtifactChanged
    case submitRecoveryArtifact
    /// The path for someone who no longer has the recovery key, after an account recovery.
    case startRecoveryThroughAccountRecovery
    case enableAlerts
    case removeAlerts(SecurityNotificationSummary)
}
