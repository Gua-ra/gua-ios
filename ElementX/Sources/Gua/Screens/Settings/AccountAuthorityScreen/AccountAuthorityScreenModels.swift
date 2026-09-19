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

/// Where the screen is in the one flow it owns.
///
/// ``artifact`` is the step ADM-009 decision 7 makes mandatory: the recovery authority key is shown once
/// and adoption is refused until the user says they stored it. There is deliberately no path from
/// ``steppingUp`` or ``enteringPin`` to ``submitting`` that skips it.
enum AccountAuthorityScreenPhase: Equatable {
    case loading
    /// The chain was read. What is shown depends on the state it reported, not on this phase.
    case overview
    /// The chain could not be read. Not the same as "this account has nothing": the screen says so and
    /// offers a retry rather than inviting a setup it cannot see the need for.
    case unavailable
    /// A passkey sheet is up, or the record is being built.
    case steppingUp
    case enteringPin
    case artifact
    case submitting
}

struct AccountAuthorityScreenViewState: BindableState {
    static let pinLength = 6

    var phase: AccountAuthorityScreenPhase = .loading
    /// What the server reports. `nil` means it has not been read, which is never rendered as "empty".
    var chain: AuthorityChainState?
    /// This device's own authority key, base64url, when it holds one for this account. It is how the
    /// list can say which row is the phone in the reader's hand.
    var thisDeviceKey: String?
    /// The recovery key, only while ``AccountAuthorityScreenPhase/artifact`` is on screen.
    var recoveryArtifact: String?
    var errorMessage: String?
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

    /// Devices in the order the chain granted them, which is the only order the chain fixes. The device
    /// in the reader's hand is lifted to the top, because that is the row they are looking for.
    var devices: [AuthorityDeviceSummary] {
        let devices = (chain?.devices ?? []).sorted { $0.grantedSeq < $1.grantedSeq }
        guard let thisDeviceKey else { return devices }
        return devices.filter { $0.deviceKey == thisDeviceKey } + devices.filter { $0.deviceKey != thisDeviceKey }
    }

    func isThisDevice(_ device: AuthorityDeviceSummary) -> Bool {
        device.deviceKey == thisDeviceKey
    }

    /// Continue is off until the confirmation is on. The server refuses an unconfirmed adoption too, so
    /// this is the screen agreeing with the rule rather than being the only thing holding it.
    var canSubmitAdoption: Bool {
        phase == .artifact && bindings.hasStoredRecoveryArtifact
    }

    var canSubmitPin: Bool {
        phase == .enteringPin && bindings.pin.count == Self.pinLength && bindings.pin.allSatisfy(\.isNumber)
    }
}

struct AccountAuthorityScreenViewStateBindings {
    var pin = ""
    /// The user's own statement that they wrote the recovery key down. Nothing else sets it.
    var hasStoredRecoveryArtifact = false
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
    /// The artifact is stored and the adoption may go ahead.
    case submitAdoption
    case cancel
    case showApprovals
}
