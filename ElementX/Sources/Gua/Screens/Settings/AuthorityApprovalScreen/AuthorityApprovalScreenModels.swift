//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation

enum AuthorityApprovalScreenViewModelAction {
    case close
}

/// What a pending approval would change, in words this app is prepared to put its name to.
///
/// The action id on the wire is opaque, and the server does not fix a vocabulary for it, because the
/// browser session names it. That leaves the device with one rule it has to keep: ADM-009 decision 6 says
/// the approval "names the action on a screen the page does not control", so a request this build cannot
/// describe is one it **refuses to sign**. Signing a digest whose meaning the reader was not shown would
/// turn the whole screen into a rubber stamp, which is the attack the code and the description defend
/// against.
enum AuthorityApprovalAction: Equatable {
    case addDevice
    case removeDevice
    /// Named something this build has no sentence for. Shown as unsignable, never as a blank approval.
    case undescribable

    init(actionID: String?) {
        switch actionID {
        case "authority.device.grant": self = .addDevice
        case "authority.device.revoke": self = .removeDevice
        default: self = .undescribable
        }
    }

    /// The sentence to show, or `nil` when there is none and the request cannot be approved here.
    var sentence: String? {
        switch self {
        case .addDevice: L10n.screenAuthorityApprovalActionAddDevice
        case .removeDevice: L10n.screenAuthorityApprovalActionRemoveDevice
        case .undescribable: nil
        }
    }

    var isSignable: Bool {
        sentence != nil
    }
}

enum AuthorityApprovalScreenPhase: Equatable {
    case loading
    /// Nothing is waiting.
    case empty
    /// One approval, ready to be read and signed.
    case approval
    /// More than one is live at once. ADM-009 decision 6 (review finding 14) has the device refuse to
    /// present one while another is live, because the four-character code is only a binding while exactly
    /// one of them is on screen.
    case tooManyLive
    case signing
    case signed
    /// The approvals could not be read, or this device holds no authority to sign with.
    case unavailable
}

struct AuthorityApprovalScreenViewState: BindableState {
    var phase: AuthorityApprovalScreenPhase = .loading
    var approval: AuthorityApproval?
    var action: AuthorityApprovalAction = .undescribable
    var errorMessage: String?

    var code: String {
        approval?.code ?? ""
    }

    /// The code as four separated characters, so a reader comparing two screens is looking at four things
    /// rather than at a word they might read as one.
    var spacedCode: String {
        code.map(String.init).joined(separator: " ")
    }

    var canSign: Bool {
        phase == .approval && action.isSignable
    }
}

enum AuthorityApprovalScreenViewAction {
    case retry
    case sign
    case close
}
