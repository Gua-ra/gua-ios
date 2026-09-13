//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation

/// GUA FORK: a factor the identity service can require, accept, or fall back to.
///
/// The names and the order are the server's: strongest first, and that order is the point. A
/// passkey is the preferred strong factor and the PIN is the fallback for whoever cannot use one,
/// so a screen offers the first factor in this list that the account holds and walks down from
/// there, instead of every screen re-deciding the rule from a single `hasPin` boolean.
///
/// Every case means REGISTERED ON THE SERVER. None of them means "usable on the device making this
/// call", which only the client can know. That difference is not cosmetic: registration is
/// something the server looks up and an attacker cannot assert, while usability is a claim, so it
/// steers what this app offers first and is never sent anywhere as an input to a security decision.
enum AuthFactor: Equatable {
    /// A WebAuthn credential registered to the account. Strongest, because a step-up assertion also
    /// proves the authenticator verified the human.
    case passkey
    /// The account PIN. The fallback for everyone who cannot produce an assertion right now.
    case pin
    /// An SMS code to the number on file. Enough to sign in and to re-authenticate, and
    /// deliberately not enough on its own to re-point the number it is delivered to.
    case phoneOTP
    /// A factor a newer server named that this build does not know. Never counted as one this
    /// client holds or can produce, so an unrecognized value can only ever make the app ask for a
    /// factor it does understand, never let it skip the step.
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

/// GUA FORK: the privileged operation a reauth token may be spent on (`/account/reauth/verify`).
///
/// The server binds the token it mints to one of these and refuses it anywhere else, so a token
/// taken out to deactivate an account cannot be redirected into a phone change. Every call site
/// names its own operation for that reason; there is no general-purpose token.
enum ReauthOperation: String {
    case deactivate = "DEACTIVATE"
    case identityReset = "IDENTITY_RESET"
    case phoneChange = "PHONE_CHANGE"
}

/// GUA FORK: what `GET /security/pin/status` reports about the account's factors.
///
/// This is the server's factor signal, and it replaces the four places that used to decide which
/// factor was required from `hasPin` alone. All of it is about registration. Nothing in it
/// describes the device in front of the user.
struct AccountSecurityStatus: Equatable {
    /// The account has a security PIN configured.
    let hasPin: Bool
    /// The account has at least one passkey registered and this deployment has passkeys enabled.
    /// It says nothing about whether the credential can be used on this device.
    let passkeyRegistered: Bool
    /// The strongest factor the account holds, and so the one to offer first. `nil` when the
    /// deployment did not report it.
    let preferredFactor: AuthFactor?
    /// The factors `POST /account/phone/change/start` accepts as its step-up, strongest first,
    /// exactly as published. Empty when the deployment did not report the list.
    let phoneChangeStepUpFactors: [AuthFactor]
    /// Seconds still to run on the fresh-2FA hold before the account PIN may be spent as the
    /// step-up factor on a phone change. `nil` means the server did not report it, which is not the
    /// same as zero: a missing value used to be read as "no hold", which left the pre-check inert.
    /// It is also silent about the separate per-account phone-change cooldown, and about the hold a
    /// freshly registered passkey carries, so read it when about to offer the PIN rather than as
    /// "can this account change its number now".
    let pinStepUpHoldRemainingSeconds: Int?

    /// Whether the account holds this factor. Registration is the only question the server answers;
    /// `phoneOTP` and anything unrecognized are counted as not held, so neither can stand in for a
    /// step-up this client does not know how to produce.
    func isRegistered(_ factor: AuthFactor) -> Bool {
        switch factor {
        case .passkey: passkeyRegistered
        case .pin: hasPin
        case .phoneOTP, .unrecognized: false
        }
    }

    /// The step-up factors this account can be offered for a phone change, strongest first.
    ///
    /// The accepted list is the server's. When a deployment does not publish one, the app falls
    /// back to passkey-then-PIN, which is what the server enforces: that keeps an older deployment
    /// working without inventing a weaker rule, and the server still has the last word, since it
    /// answers `step_up_required` to anyone who produces nothing it accepts.
    var offerablePhoneChangeStepUpFactors: [AuthFactor] {
        let accepted = phoneChangeStepUpFactors.isEmpty ? [AuthFactor.passkey, .pin] : phoneChangeStepUpFactors
        return accepted.filter(isRegistered)
    }

    /// True when the account holds a factor stronger than an SMS code, which is what the
    /// "set up two-step verification" nudges are actually asking for. A passkey holder has one.
    var holdsStrongFactor: Bool {
        hasPin || passkeyRegistered
    }
}

/// GUA FORK: a step-up ceremony minted by `POST /security/passkey/stepup/options`, pinned to the
/// authenticated caller. The `stepUpID` travels back with the assertion on the operation being
/// stepped up; the challenge is single use whether it is accepted or refused.
struct PasskeyStepUpOptions: Equatable {
    let stepUpID: String
    let relyingPartyID: String
    let challenge: Data
    let allowedCredentialIDs: [Data]
}

/// GUA FORK: a WebAuthn assertion in the JSON shape the identity service parses, the same one the
/// web sign-in UI posts.
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

    /// Sent as an empty object, matching what a browser posts for a ceremony that asked for no
    /// extensions.
    let clientExtensionResults = [String: String]()

    init(id: String, response: Response) {
        self.id = id
        rawId = id
        type = "public-key"
        self.response = response
    }
}

/// GUA FORK: the challenge `POST /account/phone/change/start` returns once the reauth token and the
/// step-up factor have both been accepted and the OTP has gone to the new number.
struct PhoneChangeChallenge: Equatable {
    let challengeID: String
    let otpExpiresInSeconds: Int
}
