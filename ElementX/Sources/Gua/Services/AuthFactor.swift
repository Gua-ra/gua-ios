//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation

/// A factor the identity service can require, accept or fall back to, strongest first: a screen
/// offers the first one the account holds and walks down from there.
///
/// Every case means registered on the server, never usable on this device. Usability is a client
/// claim, so it only steers what the app offers and is never sent as input to a security decision.
enum AuthFactor: Equatable {
    /// A WebAuthn credential registered to the account. Strongest, because a step-up assertion also
    /// proves the authenticator verified the user.
    case passkey
    /// The account PIN, the fallback when no assertion can be produced.
    case pin
    /// An SMS code to the number on file. Enough to sign in and to reauthenticate, and not enough on
    /// its own to change the number it is delivered to.
    case phoneOTP
    /// A factor a newer server named that this build does not know. Never counted as held, so an
    /// unknown value cannot skip a step-up.
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

/// The privileged operation a reauth token may be spent on (`/account/reauth/verify`). The server
/// binds the token to one operation and refuses it for any other.
enum ReauthOperation: String {
    case deactivate = "DEACTIVATE"
    case identityReset = "IDENTITY_RESET"
    case phoneChange = "PHONE_CHANGE"
}

/// What `GET /security/pin/status` reports about the account's factors. All of it is about
/// registration; nothing in it describes the device in front of the user.
struct AccountSecurityStatus: Equatable {
    let hasPin: Bool
    /// The account has at least one passkey registered and this deployment has passkeys enabled.
    let passkeyRegistered: Bool
    /// The strongest factor the account holds, and so the one to offer first. `nil` when the
    /// deployment did not report it.
    let preferredFactor: AuthFactor?
    /// The factors `POST /account/phone/change/start` accepts as its step-up, strongest first,
    /// exactly as published. Empty when the deployment did not report the list.
    let phoneChangeStepUpFactors: [AuthFactor]
    /// Remaining hold before a new PIN can step up a phone change. `nil` means not reported, never
    /// zero. Says nothing about the phone-change cooldown or the hold on a new passkey.
    let pinStepUpHoldRemainingSeconds: Int?
    /// A delayed account recovery live on the account, or `nil` when there is none or the deployment
    /// does not report recovery.
    var pendingAccountRecovery: PendingAccountRecovery?

    /// Whether the account holds this factor. `phoneOTP` and anything unrecognized count as not held,
    /// so neither can stand in for a step-up.
    func isRegistered(_ factor: AuthFactor) -> Bool {
        switch factor {
        case .passkey: passkeyRegistered
        case .pin: hasPin
        case .phoneOTP, .unrecognized: false
        }
    }

    /// The step-up factors this account can be offered for a phone change, strongest first. Falls back
    /// to passkey then PIN when the deployment publishes no list; the server still has the last word.
    var offerablePhoneChangeStepUpFactors: [AuthFactor] {
        let accepted = phoneChangeStepUpFactors.isEmpty ? [AuthFactor.passkey, .pin] : phoneChangeStepUpFactors
        return accepted.filter(isRegistered)
    }

    /// True when the account holds a factor stronger than an SMS code.
    var holdsStrongFactor: Bool {
        hasPin || passkeyRegistered
    }
}

/// A delayed account recovery that has been started and not cancelled. Finishing it sets a new PIN
/// and signs out every other device, so every signed-in device shows it with a way to cancel.
/// Both dates come from the server and either may be missing.
struct PendingAccountRecovery: Equatable {
    /// When it may be finished. At or before now means it already can be.
    let completableAt: Date?
    /// When it runs out on its own if nobody finishes it.
    let expiresAt: Date?
}

/// A step-up ceremony from `POST /security/passkey/stepup/options`, pinned to the authenticated
/// caller. `stepUpID` travels back with the assertion on the operation being stepped up; the
/// challenge is single use whether it is accepted or refused.
struct PasskeyStepUpOptions: Equatable {
    let stepUpID: String
    let relyingPartyID: String
    let challenge: Data
    let allowedCredentialIDs: [Data]
}

/// A WebAuthn assertion in the JSON shape the identity service parses, the same one the web
/// sign-in UI posts.
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

/// The challenge `POST /account/phone/change/start` returns once the reauth token and the step-up
/// factor have both been accepted and the OTP has gone to the new number.
struct PhoneChangeChallenge: Equatable {
    let challengeID: String
    let otpExpiresInSeconds: Int
}
