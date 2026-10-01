//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation

enum AuthorityApprovalScreenViewModelAction {
    case close
}

/// An action this build cannot describe is never signable.
enum AuthorityApprovalAction: Equatable {
    case addDevice
    case removeDevice
    case undescribable

    init(actionID: String?) {
        switch actionID {
        case "authority.device.grant": self = .addDevice
        case "authority.device.revoke": self = .removeDevice
        default: self = .undescribable
        }
    }

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
    case empty
    case approval
    /// Nothing is presented while more than one approval is live: the code binds the two screens only while exactly one is on screen.
    case tooManyLive
    case signing
    case signed
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
