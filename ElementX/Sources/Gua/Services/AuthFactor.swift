//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation

/// Every case means registered on the server, never usable on this device.
enum AuthFactor: Equatable {
    case passkey
    case pin
    case phoneOTP
    /// Never counted as held, so an unknown value cannot skip a step-up.
    case unrecognized(String)

    init(wireValue: String) {
        switch wireValue {
        case "PASSKEY": self = .passkey
        case "PIN": self = .pin
        case "PHONE_OTP": self = .phoneOTP
        default: self = .unrecognized(wireValue)
        }
    }
}

/// The server binds a reauth token to one operation and refuses it for any other.
enum ReauthOperation: String {
    case deactivate = "DEACTIVATE"
    case identityReset = "IDENTITY_RESET"
    case phoneChange = "PHONE_CHANGE"
}

struct AccountSecurityStatus: Equatable {
    let hasPin: Bool
    let passkeyRegistered: Bool
    let preferredFactor: AuthFactor?
    let phoneChangeStepUpFactors: [AuthFactor]
    /// Remaining hold before a new PIN can step up a phone change. `nil` means not reported, never zero.
    let pinStepUpHoldRemainingSeconds: Int?
    var pendingAccountRecovery: PendingAccountRecovery?

    func isRegistered(_ factor: AuthFactor) -> Bool {
        switch factor {
        case .passkey: passkeyRegistered
        case .pin: hasPin
        case .phoneOTP, .unrecognized: false
        }
    }

    /// Falls back to passkey then PIN when the deployment publishes no list.
    var offerablePhoneChangeStepUpFactors: [AuthFactor] {
        let accepted = phoneChangeStepUpFactors.isEmpty ? [AuthFactor.passkey, .pin] : phoneChangeStepUpFactors
        return accepted.filter(isRegistered)
    }

    var holdsStrongFactor: Bool {
        hasPin || passkeyRegistered
    }
}

struct PendingAccountRecovery: Equatable {
    let completableAt: Date?
    let expiresAt: Date?
}

struct PasskeyStepUpOptions: Equatable {
    let stepUpID: String
    let relyingPartyID: String
    let challenge: Data
    let allowedCredentialIDs: [Data]
}

struct PasskeyAssertion: Encodable, Equatable {
    let id: String
    let rawId: String
    let type: String
    let response: Response

    struct Response: Encodable, Equatable {
        let clientDataJSON: String
        let authenticatorData: String
        let signature: String
        let userHandle: String?
    }

    /// Sent as an empty object, as a browser does when no extensions were requested.
    let clientExtensionResults = [String: String]()

    init(id: String, response: Response) {
        self.id = id
        rawId = id
        type = "public-key"
        self.response = response
    }
}

struct PhoneChangeChallenge: Equatable {
    let challengeID: String
    let otpExpiresInSeconds: Int
}
