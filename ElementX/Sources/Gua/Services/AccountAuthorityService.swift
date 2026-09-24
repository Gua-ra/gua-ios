//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import CryptoKit
import Foundation
import UIKit

// MARK: - Wire objects

/// Which transition a challenge is minted for. A challenge is scoped to one purpose, so a step-up taken
/// for a phone change or a PIN change does not carry over, and neither does one taken for another
/// authority transition.
enum AuthorityPurpose: String, Equatable {
    case adopt = "ADOPT"
    case grant = "GRANT"
    case revoke = "REVOKE"
    case recover = "RECOVER"
    case approve = "APPROVE"
    /// A signed `Oppose` record. It asks for no factor: the authorization is a signature by a key the
    /// chain has active and unquarantined, and the hold gates starting a transition and never opposing
    /// one, so an owner whose only factor is fresh can still say no.
    case oppose = "OPPOSE"
    /// Binding a security-notification registration to a device authority key, or removing one that
    /// carries such a binding. The challenge is what makes the device's signature unreplayable.
    case notify = "NOTIFY"

    /// Whether a transition of this purpose may take its step-up in the web sheet.
    ///
    /// Exactly the four purposes that ask for a factor, which is the same rule the server derives from
    /// its own step-up policy (`AuthorityPolicy.canOpenStepUpSheet`). A purpose that asks for no factor
    /// would open a page with nothing to ask and record a proof of nothing, so this client refuses it
    /// here rather than spending a request to be told so.
    var canTakeAWebStepUp: Bool {
        switch self {
        case .adopt, .grant, .revoke, .recover: true
        case .approve, .oppose, .notify: false
        }
    }
}

/// The step-up an authority transition is authorized by: a user-verifying passkey assertion, or the
/// account PIN where the account holds one.
///
/// **There is no phone-code case and there must never be one** (ADM-009 decision 9). Account recovery
/// deletes every passkey and sets a caller-chosen PIN, so a code sent to the account's number, in any
/// combination, at any step, would launder identifier possession into account authority. The server
/// refuses it as well; this type is the client-side half of the same rule, and the absence of the case
/// is the enforcement.
enum AuthorityStepUp: Equatable {
    case passkey(stepUpID: String, assertion: PasskeyAssertion)
    case pin(String)
    /// The same two factors, run in the web sheet `POST /security/authority/step-up/start` opened, because
    /// the assertion cannot be produced natively on every device: a simulator, and a build with no
    /// associated domain for the deployment it is talking to, can run the ceremony on the sign-in origin
    /// and nowhere else.
    ///
    /// It carries nothing. The proof is a row the server wrote against this account, this session and this
    /// purpose, so the request that spends it presents no factor of its own and there is no token here a
    /// client could be talked into handing somewhere else. It is not a third factor and in particular not
    /// a weaker one: the page has the passkey arm and the PIN arm, and no arm that sends a code.
    case webSheet
}

/// The 32 server bytes one transition will sign, and when they stop being spendable.
struct AuthorityChallenge: Equatable {
    /// base64url without padding, as it crosses the wire.
    let challenge: String
    let expiresAt: Date
}

/// What a submission answered: the slot it took, whether it is inside a window, and its hash.
struct AuthoritySubmission: Equatable {
    let seq: Int64
    /// True while the record is inside its opposition window. A pending record already holds its `seq`.
    let isPending: Bool
    let effectiveAt: Date
    let recordHash: String
}

/// How an account's id was derived. It says nothing about whether the account holds authority today:
/// after adoption a `BOOTSTRAP` account holds authority its id does not commit, which is exactly what
/// ADM-009 decision 1 settles.
enum AuthorityAccountClass: Equatable {
    case bootstrap
    case genesis
    /// A class this build has not heard of. Reported rather than rounded to one of the two above.
    case unknown(String)

    init(wireValue: String) {
        switch wireValue {
        case "BOOTSTRAP": self = .bootstrap
        case "GENESIS": self = .genesis
        default: self = .unknown(wireValue)
        }
    }
}

/// The five states of ADM-009 decision 10. A statement about keys, not about chain length.
enum AuthorityChainStateName: Equatable {
    case bootstrap
    case adoptionPending
    case rooted
    case recoveryPending
    /// Rooted, no active device, no recovery key. Terminal by decision 7, and the app says so plainly
    /// rather than offering a second adoption, which would be the seizure O9 rejected.
    case authorityLost
    case unknown(String)

    init(wireValue: String) {
        switch wireValue {
        case "BOOTSTRAP": self = .bootstrap
        case "ADOPTION_PENDING": self = .adoptionPending
        case "ROOTED": self = .rooted
        case "RECOVERY_PENDING": self = .recoveryPending
        case "AUTHORITY_LOST": self = .authorityLost
        default: self = .unknown(wireValue)
        }
    }
}

enum AuthorityDeviceState: Equatable {
    case active
    case quarantined
    case revoked
    case unknown(String)

    init(wireValue: String) {
        switch wireValue {
        case "ACTIVE": self = .active
        case "QUARANTINED": self = .quarantined
        case "REVOKED": self = .revoked
        default: self = .unknown(wireValue)
        }
    }
}

/// One device key in the account's set.
struct AuthorityDeviceSummary: Equatable, Identifiable {
    /// The raw 32-byte Ed25519 key, base64url. It is also the identity: the chain has no other name for
    /// a device, which is why it is the id here too.
    let deviceKey: String
    let label: String
    let state: AuthorityDeviceState
    /// When the quarantine of a freshly granted device ends, while one is running.
    let quarantineUntil: Date?
    let grantedSeq: Int64

    var id: String {
        deviceKey
    }
}

/// Which record is holding the slot, which decides who may object to it and how.
enum AuthorityPendingType: Equatable {
    case adoptRoot
    case deviceGrant
    case deviceRevoke
    case authorityRecovery
    /// A type this build has not heard of. Shown as a window with no action rather than rounded to one
    /// whose opposition rules would be guessed.
    case unknown(String)

    init(wireValue: String) {
        switch wireValue {
        case "ADOPT_ROOT": self = .adoptRoot
        case "DEVICE_GRANT": self = .deviceGrant
        case "DEVICE_REVOKE": self = .deviceRevoke
        case "AUTHORITY_RECOVERY": self = .authorityRecovery
        default: self = .unknown(wireValue)
        }
    }

    /// Whether objecting to this needs a signature from a device the chain holds active.
    ///
    /// Only an adoption does not: at `seq = 1` the account holds no authority to weigh, so the honest veto
    /// is that someone who can already read this account's notifications says no. For everything else a
    /// session's word is refused, because a stolen session could otherwise veto the owner's own revocation
    /// of the thief's device.
    var needsADeviceToOppose: Bool {
        self != .adoptRoot
    }
}

/// A transition inside its window, which already holds its `seq`.
struct AuthorityPendingTransition: Equatable {
    let type: AuthorityPendingType
    let seq: Int64
    let effectiveAt: Date
    let recordHash: String
}

/// What `GET /account/authority` reports: the chain, the device set and any pending step.
struct AuthorityChainState: Equatable {
    /// The account's own permanent id. This is the one endpoint that returns one, and only ever to its
    /// own holder, because the client signs over its 34 raw bytes.
    let accountID: AccountID
    let accountClass: AuthorityAccountClass
    let state: AuthorityChainStateName
    let headSeq: Int64
    /// SHA-256 hex of the last accepted record, 64 zeros while the chain is empty.
    let headHash: String
    let devices: [AuthorityDeviceSummary]
    let pending: AuthorityPendingTransition?

    /// Whether this account may start an adoption at all: a bootstrap id with an empty chain.
    ///
    /// The server decides the same question again and is the authority on it. Asking here as well keeps
    /// the app from offering a transition it knows will be refused, which is a worse experience than not
    /// offering it and says nothing the state response did not already say.
    var canAdopt: Bool {
        accountClass == .bootstrap && state == .bootstrap && headSeq == 0 && pending == nil
    }

    /// Whether the account-recovery route, `AuthorityRecovery` with authorization `0x02`, may be offered
    /// for this chain at all.
    ///
    /// The three conditions the server states: the chain holds a committed authority, so this is not a
    /// bootstrap account's first record; the accountId does **not** commit that authority, because ADM-009
    /// decision 3 rule 3 refuses this route outright on a class `0x01` account, whose genesis-committed
    /// authority is replaced only by the key its genesis committed; and nothing is pending, because a rank-0
    /// record cannot take a slot an equal or higher rank already holds.
    ///
    /// Asked here as well as at the server for the reason ``canAdopt`` is: offering a button whose only
    /// outcome is a refusal costs the owner a challenge and a step-up to be told no, on the one screen where
    /// that is expensive.
    ///
    /// The same three conditions in the same order as gua-android's `canRecoverThroughAccountRecovery`,
    /// deliberately, down to a class this build has not heard of not being read as genesis. Two ports
    /// guessing separately about the edges of one server rule is how they came to disagree here in the
    /// first place.
    var canRecoverThroughAccountRecovery: Bool {
        accountClass != .genesis && state != .bootstrap && pending == nil
    }

    /// Devices that count as this account's authority today. A quarantined device is deliberately not
    /// one of them: it may not sign a grant, a revocation or an approval while its window runs.
    var unquarantinedActiveDevices: [AuthorityDeviceSummary] {
        devices.filter { $0.state == .active }
    }
}

/// A pending approval an authority device may sign, as the account's own device reads it.
struct AuthorityApproval: Equatable, Identifiable {
    let approvalID: String
    /// Four characters from an alphabet with no look-alikes. The browser shows the same four, and the
    /// comparison is the whole of what binds the two screens together.
    let code: String
    /// The opaque action id the starting session named. The device describes it in the reader's own
    /// words and refuses to sign one it cannot describe.
    let action: String?
    let actionDigest: String
    let challenge: String
    let expiresAt: Date

    var id: String {
        approvalID
    }
}

/// A public key another device of this account has offered for a grant (ADM-009 decision 5, revision 4).
///
/// The new device posts only its public key under its own session. What crosses between the two phones
/// after that is the fingerprint, and the fingerprint alone: the granting device never receives a private
/// key and the new device never receives one either.
struct AuthorityCandidate: Equatable, Identifiable {
    /// The raw 32-byte Ed25519 key, base64url.
    let deviceKeyB64: String
    /// The eight characters the server computed. This client recomputes them from the key rather than
    /// showing this string, because a fingerprint the server chose would only prove both phones had
    /// spoken to the same server.
    let fingerprint: String
    let label: String
    let expiresAt: Date

    var id: String {
        deviceKeyB64
    }
}

/// What one install registers as a security-notification destination (ADM-009 gate 2).
struct SecurityNotificationRegistration: Equatable {
    /// Client-generated, held in the keychain, stable across sign-out. The upsert key.
    let installationID: String
    /// `APNS` on this platform. The enum exists on the server for both clients.
    let platform: String
    /// The APNs device token, hex as the pusher sends it.
    let token: String
    /// The same app id the Matrix pusher already sends, so the topic is picked from one constant.
    let appID: String
    let deviceLabel: String?
    /// The device authority key this install holds, base64url, when it holds one. Accepted only with a
    /// challenge and a signature by that key: the field is what makes removing this registration from
    /// another install need a signature, so a claimed one could plant a row the owner cannot remove.
    let authorityDeviceKeyB64: String?
    let challenge: String?
    let signature: String?
}

/// One registration as its own account holder is allowed to see it. Never the destination itself.
struct SecurityNotificationSummary: Equatable, Identifiable {
    let installationID: String
    let platform: String
    let deviceLabel: String
    /// SHA-256 hex of the token, so a row can be named in a list without printing where it points.
    let tokenFingerprint: String
    /// Whether removing it from another install needs a device signature.
    let isBoundToAnAuthorityDevice: Bool
    let lastSeenAt: Date

    var id: String {
        installationID
    }
}

/// What a removal presents. Which tier it reaches is decided by what it can produce, never by a flag it
/// sets: naming your own install needs nothing else, naming another needs a factor past the fresh-factor
/// hold plus a device signature where the row carries a key.
struct SecurityNotificationRemoval: Equatable {
    let installationID: String
    let callerInstallationID: String?
    let stepUp: AuthorityStepUp?
    let challenge: String?
    let signature: String?
}

/// The slice of identity-service the authority chain needs.
///
/// Narrow rather than folded into ``IdentityServiceClientProtocol``, exactly as ``AccountGenesisRegistering``
/// is: these calls exist only behind an off-by-default flag, and a screen that has no business with the
/// chain should not be handed the chain.
protocol AccountAuthorityRequesting: Sendable {
    /// Mints the challenge one transition will sign, spending the step-up in the same call so the
    /// step-up can never be older than the challenge it authorizes.
    ///
    /// `stepUp` is `nil` for the two purposes that ask for none: an `Oppose`, whose authorization is a
    /// signature by a key the chain already holds active, and a notification binding, which is the same.
    /// Passing an empty factor instead would read as presenting one.
    func authorityChallenge(accessToken: String,
                            purpose: AuthorityPurpose,
                            stepUp: AuthorityStepUp?) async throws -> AuthorityChallenge
    /// Mints the one-time URL of the web step-up one transition is scoped to
    /// (`POST /security/authority/step-up/start`).
    ///
    /// The same handoff factor enrollment already uses, carrying a purpose instead of a factor to add. The
    /// page runs the assertion or asks for the PIN and records the proof itself, so nothing comes back
    /// here except the URL to open: the challenge is then asked for in the ordinary way, with no factor in
    /// the request, from the session that opened the sheet.
    func startAuthorityWebStepUp(accessToken: String,
                                 purpose: AuthorityPurpose,
                                 redirectURI: String?) async throws -> URL
    func submitAuthorityAdoption(accessToken: String,
                                 record: String,
                                 signature: String,
                                 challenge: String,
                                 recoveryArtifactConfirmed: Bool) async throws -> AuthoritySubmission
    func submitAuthorityDeviceGrant(accessToken: String,
                                    record: String,
                                    signature: String,
                                    challenge: String) async throws -> AuthoritySubmission
    func submitAuthorityDeviceRevoke(accessToken: String,
                                     record: String,
                                     signature: String,
                                     challenge: String) async throws -> AuthoritySubmission
    func submitAuthorityRecovery(accessToken: String,
                                 record: String,
                                 signature: String,
                                 challenge: String) async throws -> AuthoritySubmission
    /// The session-authorized opposition of ADM-009 decision 4. It may cancel an **adoption** and nothing
    /// else: accepting a session's word for a grant or a revocation would let a stolen session veto the
    /// owner's own revocation of the thief's device.
    ///
    /// `stepUp` is `nil` for the first opposition, which needs no factor beyond the session, and carries
    /// one from the second onward.
    func opposeAuthorityAdoption(accessToken: String,
                                 recordHash: String?,
                                 stepUp: AuthorityStepUp?) async throws
    /// The signed `Oppose` record, which is the claim a session cannot make. It takes no slot and starts
    /// no window: it cancels the record it names, or it is refused.
    func submitAuthorityOpposition(accessToken: String,
                                   record: String,
                                   signature: String,
                                   challenge: String) async throws
    func registerAuthorityCandidate(accessToken: String,
                                    deviceKeyB64: String,
                                    label: String) async throws -> AuthorityCandidate
    func authorityCandidates(accessToken: String) async throws -> [AuthorityCandidate]
    func registerSecurityNotification(accessToken: String,
                                      registration: SecurityNotificationRegistration) async throws -> SecurityNotificationSummary
    func securityNotifications(accessToken: String) async throws -> [SecurityNotificationSummary]
    func removeSecurityNotification(accessToken: String, removal: SecurityNotificationRemoval) async throws
    func authorityState(accessToken: String) async throws -> AuthorityChainState
    func liveAuthorityApprovals(accessToken: String) async throws -> [AuthorityApproval]
    func signAuthorityApproval(accessToken: String, approvalID: String, signature: String) async throws
}

// MARK: - The recovery artifact

/// The one thing the user has to take away from adoption, and the copy rules around it.
///
/// ADM-009 decision 7 makes losing every device and this key permanent: the account keeps its id, its
/// login and its data and never regains authority, because a second adoption authorized by login factors
/// alone is the seizure O9 rejected. That is why adoption **requires** the artifact to be taken: it is
/// shown once, the app confirms the user stored it, and adoption is refused without that confirmation.
enum AuthorityRecoveryArtifact {
    /// Names the framework and the version, so a future framework 0x02 artifact is not mistaken for this
    /// one.
    ///
    /// It is the first whitespace-separated token of every artifact, and it is the reason this format is
    /// the same on every platform rather than nearly the same: the artifact never crosses the wire, so a
    /// client that rendered one shape and accepted another could only be caught by a person who had lost
    /// their phone and was holding a key the new phone refuses. The string, the grouping and the forms a
    /// decoder accepts are pinned for all three ports in `authority-vectors.v1.json`.
    static let prefix = "gua-recovery-1"

    /// The key as the user copies it: the prefix, then RFC 4648 base32, lowercase, unpadded, in groups
    /// of four.
    ///
    /// Base32 rather than hex or base64 because this is read off one screen and typed into something
    /// else: the alphabet the accountId already uses has no case to get wrong and no `+` or `/` to lose
    /// to an autocorrect, and 32 bytes come to 52 characters, which is 13 groups.
    static func render(_ key: Curve25519.Signing.PrivateKey) -> String {
        let encoded = GuaBase32.encode([UInt8](key.rawRepresentation))
        let groups = stride(from: 0, to: encoded.count, by: 4).map { offset in
            let start = encoded.index(encoded.startIndex, offsetBy: offset)
            let end = encoded.index(start, offsetBy: min(4, encoded.count - offset))
            return String(encoded[start..<end])
        }
        return ([prefix] + groups).joined(separator: " ")
    }

    /// Characters the encoding produces, so a typo can be named before anything is submitted.
    static let keyLength = AuthorityRecord.keyLength
    /// 32 bytes of base32 come to 52 characters.
    static let encodedLength = 52

    /// Reads back what ``render(_:)`` showed, on this platform or on the other one.
    ///
    /// Whitespace and case are forgiven, because the value was read off one screen and typed into another
    /// and the encoding has neither. Everything else is refused **here**, before any request is made: the
    /// endpoint that would receive it starts a window and burns a challenge, so a mistyped key that reaches
    /// it costs the owner a cooldown rather than a second try.
    static func parse(_ typed: String) throws -> Curve25519.Signing.PrivateKey {
        guard let body = body(of: typed), body.count == encodedLength else {
            throw AccountAuthorityServiceError.artifactMalformed
        }
        let raw: [UInt8]
        do {
            raw = try GuaBase32.decode(body)
        } catch {
            throw AccountAuthorityServiceError.artifactMalformed
        }
        guard raw.count == keyLength else { throw AccountAuthorityServiceError.artifactMalformed }
        do {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: Data(raw))
        } catch {
            throw AccountAuthorityServiceError.artifactMalformed
        }
    }

    /// Whether what has been typed is as long as a whole artifact, so the button that submits it can be
    /// offered when it is and not before. Not a validity check: ``parse(_:)`` is what refuses, and its
    /// refusal is the one a person can read.
    static func looksComplete(_ typed: String) -> Bool {
        body(of: typed)?.count == encodedLength
    }

    /// The value's own characters, with the prefix taken off and the spacing collapsed, or `nil` when what
    /// was typed is not an artifact of this framework at all.
    ///
    /// Spacing between groups is free-form, because nobody retypes four-character groups exactly as they
    /// were printed. Case is forgiven the same way, by ``foldingASCIICase(_:)``.
    private static func body(of typed: String) -> String? {
        let tokens = foldingASCIICase(typed).split(whereSeparator: \.isWhitespace)
        guard let first = tokens.first, String(first) == prefix else { return nil }
        return tokens.dropFirst().joined()
    }

    /// Lowercases A through Z and leaves every other character alone.
    ///
    /// Not `lowercased()`, which this used to be. That applies the full Unicode mapping, so it folds scalars
    /// nobody on this path types onto alphabet letters, the Kelvin sign onto `k` among them, and gua-android
    /// folds neither. The alphabet is a to z with 2 to 7, so an ASCII capital names one alphabet letter and
    /// no other: reading either case admits no byte string a lowercase spelling could not already name, which
    /// is why case is forgiven at all. Anything wider than that is a second spelling arriving from somewhere
    /// nobody typed, so it stops here, and the golden vectors pin both halves rather than leaving the two
    /// ports to agree by accident.
    private static func foldingASCIICase(_ value: String) -> String {
        String(value.map { character in
            // The guard is the whole of the rule: inside it `lowercased()` is ASCII and is one character.
            character.isASCII && ("A"..."Z").contains(character) ? Character(character.lowercased()) : character
        })
    }
}

/// A record that mints a new recovery authority key, built, signed and ready, waiting only on the user
/// confirming they stored the artifact.
///
/// Two record types reach this: `AdoptRoot`, which roots the account, and `AuthorityRecovery`, which
/// replaces the device set. Both commit a **new** recovery authority key, so both are refused until the
/// user says they have stored it, and for the same reason: ADM-009 decision 7's end state is permanent.
/// One type rather than two, because the rule is the same and a second copy of it is a second place for it
/// to go missing.
///
/// A class rather than a struct so the confirmation cannot be forged by a caller assembling its own
/// value: ``confirmArtifactStored()`` is the only way to set it, and it wipes the artifact from this
/// object as it does, which is what "shown once" means in code.
@MainActor
final class PreparedAuthorityRecord {
    /// Which record this is, and therefore which endpoint submits it and what the copy around it says.
    enum Kind: Equatable {
        case adoption
        /// `AuthorityRecovery` authorized by the committed recovery authority key: rank 2, which no
        /// pending record blocks and no device can cancel.
        case recoveryUnderRecoveryKey
        /// `AuthorityRecovery` authorized through a completed account recovery: rank 0, vetoable by any
        /// active device immediately, and refused outright on a genesis-rooted account.
        case recoveryThroughAccountRecovery
    }

    let kind: Kind
    let accountID: AccountID
    /// base64url of the canonical `AdoptRoot` bytes.
    let record: String
    /// base64url of the 64 detached signature bytes.
    let signature: String
    /// The challenge inside that signature, sent back because the server holds only its hash.
    let challenge: String
    let deviceLabel: String

    /// The artifact, until it has been confirmed. `nil` afterwards.
    private(set) var recoveryArtifact: String?
    private(set) var isArtifactConfirmed = false

    init(kind: Kind,
         accountID: AccountID,
         record: String,
         signature: String,
         challenge: String,
         deviceLabel: String,
         recoveryArtifact: String) {
        self.kind = kind
        self.accountID = accountID
        self.record = record
        self.signature = signature
        self.challenge = challenge
        self.deviceLabel = deviceLabel
        self.recoveryArtifact = recoveryArtifact
    }

    /// The user says they have stored the key. Adoption is unreachable until this has been called.
    func confirmArtifactStored() {
        isArtifactConfirmed = true
        recoveryArtifact = nil
    }
}

// MARK: - Errors

enum AccountAuthorityServiceError: Error, Equatable {
    /// The flag is off. Nothing was generated, stored or sent.
    case disabled
    /// The adoption was submitted without the user confirming they stored the recovery artifact. The
    /// server refuses this too; refusing it here means the request is never made.
    case artifactUnconfirmed
    case keyUnavailable
    case signingFailed
    case malformedServerValue
    /// This device holds no authority key for the account, so there is nothing for it to sign with.
    case notAnAuthorityDevice
    /// The typed or imported recovery key is not one this encoding produces. Refused before submission.
    case artifactMalformed
    /// The recovery key that was entered is not the one the account's chain committed. Caught here by
    /// comparing public halves, so the owner is told they have the wrong key rather than watching a
    /// window open and a signature fail.
    case artifactNotThisAccount
    /// The fingerprint the granting device recomputed from the offered key does not match the one the
    /// server sent beside it, or the human comparison was not confirmed. Either way nothing is signed.
    case candidateUnverified
    /// This install has no push destination to register, so there is no channel to offer.
    case noPushToken
}

// MARK: - The service

@MainActor
protocol AccountAuthorityServiceProtocol {
    /// The feature flag. While false nothing in this file runs.
    var isEnabled: Bool { get }

    func state(accessToken: String) async throws -> AuthorityChainState

    /// The URL of the web sheet a transition of this purpose can take its step-up in, for a device that
    /// cannot run the native ceremony.
    ///
    /// The fallback the native assertion falls back to, and deliberately not the PIN: a passkey-only
    /// account must never be told to add a weaker factor in order to gain authority (C4). What the sheet
    /// leaves behind is a proof the server recorded, spent by passing ``AuthorityStepUp/webSheet`` to the
    /// transition, from the same session that opened it.
    ///
    /// Refused locally for a purpose that asks for no factor, so no request goes out for a page that
    /// would have nothing to ask.
    func webStepUpURL(accessToken: String, purpose: AuthorityPurpose) async throws -> URL

    /// Runs everything adoption needs before the user is asked to store the recovery key: the scoped
    /// step-up and its challenge, the two keys, the record and its signature.
    ///
    /// Nothing reaches the chain here. A client that stops between this call and ``submit(accessToken:prepared:)``
    /// has produced nothing the server has seen, and its keys are garbage it replaces next time.
    func prepareAdoption(accessToken: String,
                         accountID: AccountID,
                         stepUp: AuthorityStepUp) async throws -> PreparedAuthorityRecord

    /// Builds and signs an `AuthorityRecovery` under the recovery key the user just typed back.
    ///
    /// The typed material is parsed and matched against the account's own chain **before** the challenge
    /// is minted, so a wrong or mistyped key costs a message rather than a burned challenge and a cooldown.
    func prepareRecovery(accessToken: String,
                         state: AuthorityChainState,
                         typedArtifact: String,
                         stepUp: AuthorityStepUp) async throws -> PreparedAuthorityRecord

    /// Builds and signs an `AuthorityRecovery` authorized through a completed account recovery.
    ///
    /// The weaker of the two paths, deliberately: it is signed by the device key it installs, any active
    /// device can veto it the moment it lands, and it is refused on a genesis-rooted account.
    func prepareRecoveryThroughAccountRecovery(accessToken: String,
                                               state: AuthorityChainState,
                                               stepUp: AuthorityStepUp) async throws -> PreparedAuthorityRecord

    /// Submits a prepared record. Refuses locally while the artifact is unconfirmed.
    func submit(accessToken: String, prepared: PreparedAuthorityRecord) async throws -> AuthoritySubmission

    /// Offers this device's own public key as a candidate for a grant, and returns the fingerprint the
    /// other phone has to match. Only the public half leaves this device, ever.
    func offerThisDevice(accessToken: String, state: AuthorityChainState) async throws -> AuthorityCandidate

    /// The keys other devices of this account have offered. What a grant may name, and nothing else.
    func candidates(accessToken: String) async throws -> [AuthorityCandidate]

    /// Signs a `DeviceGrant` over a candidate this account offered.
    ///
    /// Refuses unless the fingerprint this device recomputes from the offered key equals the one the
    /// server sent beside it, and unless the caller states the human comparison was made. The first check
    /// is what makes the fingerprint mean the key rather than meaning the server; the second is the reason
    /// the fingerprint exists at all.
    func signDeviceGrant(accessToken: String,
                         state: AuthorityChainState,
                         candidate: AuthorityCandidate,
                         comparisonConfirmed: Bool,
                         stepUp: AuthorityStepUp) async throws -> AuthoritySubmission

    /// Signs a `DeviceRevoke`. Revoking another device waits out the window and is notified; revoking this
    /// device's own key takes effect at once, which the server decides and reports.
    func revokeDevice(accessToken: String,
                      state: AuthorityChainState,
                      deviceKey: String,
                      reason: UInt8,
                      stepUp: AuthorityStepUp) async throws -> AuthoritySubmission

    /// Objects to the pending transition, by whichever route ADM-009 permits for its type.
    ///
    /// An adoption is opposed by the session, because at `seq = 1` there is no device yet. Everything else
    /// is opposed by a signed `Oppose` record from a key the chain has active, because a stolen session
    /// must not be able to veto the owner's own revocation of the thief's device.
    func oppose(accessToken: String,
                state: AuthorityChainState,
                pending: AuthorityPendingTransition,
                stepUp: AuthorityStepUp?) async throws

    /// Registers this install as a security-notification destination, binding it to this device's
    /// authority key where it holds one.
    func registerSecurityAlerts(accessToken: String,
                                accountID: AccountID) async throws -> SecurityNotificationSummary

    func securityAlerts(accessToken: String) async throws -> [SecurityNotificationSummary]

    /// Removes one registration. Naming this install needs no factor; naming another needs a step-up and,
    /// where the row carries a device key, a signature by this device's key.
    func removeSecurityAlerts(accessToken: String,
                              accountID: AccountID,
                              installationID: String,
                              stepUp: AuthorityStepUp?) async throws

    /// This install's own id, so a listing can say which row is the phone in the reader's hand.
    func thisInstallationID() -> String?

    func liveApprovals(accessToken: String) async throws -> [AuthorityApproval]

    /// Signs one browser-started approval with this device's authority key.
    func signApproval(accessToken: String, approval: AuthorityApproval, state: AuthorityChainState) async throws

    /// This device's own authority key as it appears in the chain, base64url, or `nil` when this device
    /// holds none for the account.
    func thisDeviceKey(accountID: AccountID) -> String?
}

/// The client half of ADM-009: adoption, the device set as this device can read it, a grant signed in
/// the permitted direction, and the signature a browser session cannot produce for itself.
///
/// Off by default and off is a hard off: with `guaAccountAuthorityEnabled` down, no key is generated, no
/// request is made and no screen is reachable. Nothing here touches login, recovery, factor enrollment or
/// genesis, and no existing call site changes behaviour either way.
@MainActor
final class AccountAuthorityService: AccountAuthorityServiceProtocol {
    private let client: AccountAuthorityRequesting
    private let keyStore: AccountAuthorityKeyStoreProtocol
    private let installationIDStore: AuthorityInstallationIDStoreProtocol
    private let pushTokenStore: AuthorityPushTokenStore
    private let appSettings: AppSettings
    /// What a record's 16-byte label will say. Read once so a rename mid-flow cannot make the label in
    /// the signature differ from the one the screen showed.
    private let deviceLabel: String

    init(client: AccountAuthorityRequesting,
         keyStore: AccountAuthorityKeyStoreProtocol,
         installationIDStore: AuthorityInstallationIDStoreProtocol,
         pushTokenStore: AuthorityPushTokenStore,
         appSettings: AppSettings,
         deviceLabel: String = UIDevice.current.name) {
        self.client = client
        self.keyStore = keyStore
        self.installationIDStore = installationIDStore
        self.pushTokenStore = pushTokenStore
        self.appSettings = appSettings
        self.deviceLabel = deviceLabel
    }

    /// Convenience initializer for the app, returning `nil` when this build has no identity service
    /// configured, which is the same condition under which every other Gua account screen fails closed.
    convenience init?(appSettings: AppSettings) {
        guard let client = IdentityServiceClient() else { return nil }
        self.init(client: client,
                  keyStore: AccountAuthorityKeyStore(),
                  installationIDStore: AuthorityInstallationIDStore(),
                  pushTokenStore: .shared,
                  appSettings: appSettings)
    }

    var isEnabled: Bool {
        appSettings.guaAccountAuthorityEnabled
    }

    func state(accessToken: String) async throws -> AuthorityChainState {
        guard isEnabled else { throw AccountAuthorityServiceError.disabled }
        return try await client.authorityState(accessToken: accessToken)
    }

    func webStepUpURL(accessToken: String, purpose: AuthorityPurpose) async throws -> URL {
        guard isEnabled else { throw AccountAuthorityServiceError.disabled }
        // The purposes that ask for no factor never open a sheet. The server refuses them too, in the same
        // words; refusing here as well keeps a request from being spent on a page with nothing to ask.
        guard purpose.canTakeAWebStepUp else {
            throw IdentityServiceError.authority(.stepUpSheetPurposeRefused)
        }
        // This build's own redirect, which is how the sheet finds its way back to the variant it was
        // opened from. Asking for it is all the client does: the deployment keeps the allowlist, and the
        // client asks again without one when it is refused, exactly as factor enrollment does.
        return try await client.startAuthorityWebStepUp(accessToken: accessToken,
                                                        purpose: purpose,
                                                        redirectURI: appSettings.oidcRedirectURL.absoluteString)
    }

    func prepareAdoption(accessToken: String,
                         accountID: AccountID,
                         stepUp: AuthorityStepUp) async throws -> PreparedAuthorityRecord {
        // The flag gate, ahead of anything being generated, stored or sent. Callers check `isEnabled`
        // too; this is here so the service cannot be made to act while the flag is down.
        guard isEnabled else { throw AccountAuthorityServiceError.disabled }

        // The step-up travels with the challenge request, so "a step-up no older than the challenge"
        // (decision 4 step 2) holds by construction rather than by two clocks agreeing.
        let challenge = try await client.authorityChallenge(accessToken: accessToken,
                                                            purpose: .adopt,
                                                            stepUp: stepUp)
        guard let challengeBytes = GuaBase64URL.decode(challenge.challenge),
              challengeBytes.count == AuthorityRecord.challengeLength else {
            throw AccountAuthorityServiceError.malformedServerValue
        }

        let keyPair = keyStore.generateKeyPair()
        var entropy = [UInt8](repeating: 0, count: AuthorityRecord.entropyLength)
        guard SecRandomCopyBytes(kSecRandomDefault, entropy.count, &entropy) == errSecSuccess else {
            throw AccountAuthorityServiceError.keyUnavailable
        }

        let canonicalBytes = try AuthorityRecord.adoptRoot(accountID: accountID,
                                                           deviceKey: [UInt8](keyPair.authority.publicKey.rawRepresentation),
                                                           recoveryKey: [UInt8](keyPair.recovery.publicKey.rawRepresentation),
                                                           label: deviceLabel,
                                                           entropy: entropy)
        // Read back what we just built before signing it, for the reason the genesis client decodes its
        // own genesis: the chain is the authority, so bytes this app would refuse are bytes it must not
        // ask a server to write.
        try AuthorityRecord.validate(canonicalBytes)

        let preimage = try AuthorityProofs.recordPreimage(type: .adoptRoot,
                                                          challenge: challengeBytes,
                                                          canonicalBytes: canonicalBytes)
        let signature: Data
        do {
            signature = try keyPair.authority.signature(for: Data(preimage))
        } catch {
            throw AccountAuthorityServiceError.signingFailed
        }

        // Stored before the submission, exactly as the genesis registration does it: an adoption that
        // is accepted while its reply is lost still has its key on this device. A definite refusal drops
        // them again in `submitAdoption`.
        //
        // A store that refuses ends the adoption here. Carrying on would submit a record committing a key
        // this device cannot read back, which is an account rooted on nothing and, by decision 7, rooted
        // on nothing permanently.
        do {
            try keyStore.persist(keyPair, forAccountID: accountID.value)
        } catch {
            throw AccountAuthorityServiceError.keyUnavailable
        }

        return PreparedAuthorityRecord(kind: .adoption,
                                       accountID: accountID,
                                       record: GuaBase64URL.encode(canonicalBytes),
                                       signature: GuaBase64URL.encode([UInt8](signature)),
                                       challenge: challenge.challenge,
                                       deviceLabel: AuthorityLabel.decode(AuthorityLabel.encode(deviceLabel)),
                                       recoveryArtifact: AuthorityRecoveryArtifact.render(keyPair.recovery))
    }

    func submit(accessToken: String, prepared: PreparedAuthorityRecord) async throws -> AuthoritySubmission {
        guard isEnabled else { throw AccountAuthorityServiceError.disabled }
        // Neither record is reachable without the confirmation, which is a rule rather than a prompt
        // (ADM-009 decision 7). The server refuses an unconfirmed adoption as well; this is why the
        // request is never made.
        guard prepared.isArtifactConfirmed else { throw AccountAuthorityServiceError.artifactUnconfirmed }

        do {
            switch prepared.kind {
            case .adoption:
                return try await client.submitAuthorityAdoption(accessToken: accessToken,
                                                                record: prepared.record,
                                                                signature: prepared.signature,
                                                                challenge: prepared.challenge,
                                                                recoveryArtifactConfirmed: true)
            case .recoveryUnderRecoveryKey, .recoveryThroughAccountRecovery:
                return try await client.submitAuthorityRecovery(accessToken: accessToken,
                                                                record: prepared.record,
                                                                signature: prepared.signature,
                                                                challenge: prepared.challenge)
            }
        } catch let error as IdentityServiceError {
            // A refusal the server made up its mind about: the record is not on the chain and never will
            // be under this challenge, so the keys are garbage. A transport failure is not that, and its
            // keys stay: the submission may well have been accepted.
            if case .authority = error {
                keyStore.removeKeys(forAccountID: prepared.accountID.value)
            }
            throw error
        }
    }

    func prepareRecovery(accessToken: String,
                         state: AuthorityChainState,
                         typedArtifact: String,
                         stepUp: AuthorityStepUp) async throws -> PreparedAuthorityRecord {
        guard isEnabled else { throw AccountAuthorityServiceError.disabled }

        // Parsed and matched before anything is minted. The endpoint this would reach starts a window and
        // burns a challenge, so a mistyped key that got that far would cost the owner a cooldown.
        let recoveryKey = try AuthorityRecoveryArtifact.parse(typedArtifact)
        let recoveryPublicKey = [UInt8](recoveryKey.publicKey.rawRepresentation)
        // The chain does not publish the committed recovery key, so the mismatch that can be caught here
        // is the one that matters in practice: a key that is not even this account's device key, and a key
        // that is 32 valid bytes of something else. The server settles it by verifying the signature.
        guard !state.devices.contains(where: { $0.deviceKey == GuaBase64URL.encode(recoveryPublicKey) }) else {
            throw AccountAuthorityServiceError.artifactNotThisAccount
        }

        return try await prepareRecoveryRecord(accessToken: accessToken,
                                               state: state,
                                               authorization: AuthorityRecord.authorizationRecoveryKey,
                                               signWith: recoveryKey,
                                               authorizingKey: recoveryPublicKey,
                                               stepUp: stepUp)
    }

    func prepareRecoveryThroughAccountRecovery(accessToken: String,
                                               state: AuthorityChainState,
                                               stepUp: AuthorityStepUp) async throws -> PreparedAuthorityRecord {
        guard isEnabled else { throw AccountAuthorityServiceError.disabled }
        // Nothing is passed for the authorizing key: under this path the field is 32 zero bytes by rule and
        // the record is signed by the device key it installs, which is generated inside the call below.
        return try await prepareRecoveryRecord(accessToken: accessToken,
                                               state: state,
                                               authorization: AuthorityRecord.authorizationAccountRecovery,
                                               signWith: nil,
                                               authorizingKey: AuthorityRecord.zeroKey,
                                               stepUp: stepUp)
    }

    /// The half both recovery paths share: a new device key, a new recovery key, the record, and the
    /// signature of whichever key the path names as its signer.
    private func prepareRecoveryRecord(accessToken: String,
                                       state: AuthorityChainState,
                                       authorization: UInt8,
                                       signWith committedRecoveryKey: Curve25519.Signing.PrivateKey?,
                                       authorizingKey: [UInt8],
                                       stepUp: AuthorityStepUp) async throws -> PreparedAuthorityRecord {
        guard let prevHash = AuthorityRecord.hashBytes(fromHex: state.headHash),
              state.headSeq >= 0, state.headSeq < Int64.max else {
            throw AccountAuthorityServiceError.malformedServerValue
        }

        let challenge = try await client.authorityChallenge(accessToken: accessToken,
                                                            purpose: .recover,
                                                            stepUp: stepUp)
        guard let challengeBytes = GuaBase64URL.decode(challenge.challenge),
              challengeBytes.count == AuthorityRecord.challengeLength else {
            throw AccountAuthorityServiceError.malformedServerValue
        }

        // A recovery replaces the device set with one device and installs a new recovery authority key in
        // the same record, so both are fresh: reusing the old recovery key would mean a recovery that does
        // not recover from the key being known.
        let keyPair = keyStore.generateKeyPair()
        var entropy = [UInt8](repeating: 0, count: AuthorityRecord.entropyLength)
        guard SecRandomCopyBytes(kSecRandomDefault, entropy.count, &entropy) == errSecSuccess else {
            throw AccountAuthorityServiceError.keyUnavailable
        }

        let canonicalBytes = try AuthorityRecord.authorityRecovery(accountID: state.accountID,
                                                                   deviceKey: [UInt8](keyPair.authority.publicKey.rawRepresentation),
                                                                   recoveryKey: [UInt8](keyPair.recovery.publicKey.rawRepresentation),
                                                                   label: deviceLabel,
                                                                   entropy: entropy,
                                                                   authorization: authorization,
                                                                   authorizingKey: authorizingKey,
                                                                   prevHash: prevHash,
                                                                   seq: UInt64(state.headSeq) + 1)
        try AuthorityRecord.validate(canonicalBytes)

        let preimage = try AuthorityProofs.recordPreimage(type: .authorityRecovery,
                                                          challenge: challengeBytes,
                                                          canonicalBytes: canonicalBytes)
        let signature: Data
        do {
            // The signer is the path, not a choice: the committed recovery key under rank 2, and the
            // device key being installed under rank 0, where the account has no other key left.
            signature = try (committedRecoveryKey ?? keyPair.authority).signature(for: Data(preimage))
        } catch {
            throw AccountAuthorityServiceError.signingFailed
        }

        // Stored before the submission, for the reason adoption stores its pair: a recovery that is
        // accepted while its reply is lost still has its key on this device. A store that refuses ends the
        // recovery here rather than committing a key this phone cannot read back.
        do {
            try keyStore.persist(keyPair, forAccountID: state.accountID.value)
        } catch {
            throw AccountAuthorityServiceError.keyUnavailable
        }

        let kind: PreparedAuthorityRecord.Kind = authorization == AuthorityRecord.authorizationRecoveryKey
            ? .recoveryUnderRecoveryKey
            : .recoveryThroughAccountRecovery
        return PreparedAuthorityRecord(kind: kind,
                                       accountID: state.accountID,
                                       record: GuaBase64URL.encode(canonicalBytes),
                                       signature: GuaBase64URL.encode([UInt8](signature)),
                                       challenge: challenge.challenge,
                                       deviceLabel: AuthorityLabel.decode(AuthorityLabel.encode(deviceLabel)),
                                       recoveryArtifact: AuthorityRecoveryArtifact.render(keyPair.recovery))
    }

    func offerThisDevice(accessToken: String, state: AuthorityChainState) async throws -> AuthorityCandidate {
        guard isEnabled else { throw AccountAuthorityServiceError.disabled }
        let accountID = state.accountID

        // The key this device already holds for the account, when it holds one and the chain does not name
        // it yet. Generating a second one in that case would leave the phone with two answers to "which key
        // is mine" and would orphan whichever the chain ends up naming.
        //
        // A key the chain already names is a different matter and a fresh pair is generated instead. A
        // revoked key offered back is a revocation with no effect, and the chain cannot say whether it was
        // removed because the phone was lost or because it was in someone else's hands, so re-admitting it
        // would be this client deciding that question on the owner's behalf.
        let authorityKey: Curve25519.Signing.PrivateKey
        let stored = try? keyStore.authorityKey(forAccountID: accountID.value)
        let storedKeyIsInTheChain = stored.map { key in
            let encoded = GuaBase64URL.encode([UInt8](key.publicKey.rawRepresentation))
            return state.devices.contains { $0.deviceKey == encoded }
        } ?? false

        if let stored, !storedKeyIsInTheChain {
            authorityKey = stored
        } else {
            let keyPair = keyStore.generateKeyPair()
            // The recovery half of the pair is stored and never committed: only an AdoptRoot and an
            // AuthorityRecovery commit a recovery authority key, and a granted device writes neither.
            do {
                try keyStore.persist(keyPair, forAccountID: accountID.value)
            } catch {
                throw AccountAuthorityServiceError.keyUnavailable
            }
            authorityKey = keyPair.authority
        }

        let publicKey = [UInt8](authorityKey.publicKey.rawRepresentation)
        let candidate = try await client.registerAuthorityCandidate(accessToken: accessToken,
                                                                    deviceKeyB64: GuaBase64URL.encode(publicKey),
                                                                    label: deviceLabel)
        // The fingerprint this phone shows is the one it computed, not the one it was sent. A server-issued
        // string would make the comparison across the room mean "both spoke to the same server", which is
        // already assumed and is not the property being checked.
        guard let computed = AuthorityFingerprint.of(publicKey) else {
            throw AccountAuthorityServiceError.malformedServerValue
        }
        return AuthorityCandidate(deviceKeyB64: candidate.deviceKeyB64,
                                  fingerprint: computed,
                                  label: candidate.label,
                                  expiresAt: candidate.expiresAt)
    }

    func candidates(accessToken: String) async throws -> [AuthorityCandidate] {
        guard isEnabled else { throw AccountAuthorityServiceError.disabled }
        return try await client.authorityCandidates(accessToken: accessToken).compactMap { candidate in
            // A candidate whose key this build cannot read is dropped rather than shown with the server's
            // fingerprint beside it: a row a user could confirm without the comparison meaning anything is
            // worse than a row that is not there.
            guard let key = GuaBase64URL.decode(candidate.deviceKeyB64),
                  let computed = AuthorityFingerprint.of(key) else {
                return nil
            }
            return AuthorityCandidate(deviceKeyB64: candidate.deviceKeyB64,
                                      fingerprint: computed,
                                      label: candidate.label,
                                      expiresAt: candidate.expiresAt)
        }
    }

    func signDeviceGrant(accessToken: String,
                         state: AuthorityChainState,
                         candidate: AuthorityCandidate,
                         comparisonConfirmed: Bool,
                         stepUp: AuthorityStepUp) async throws -> AuthoritySubmission {
        guard isEnabled else { throw AccountAuthorityServiceError.disabled }
        // The fingerprint is the only thing binding the key to the person holding the other phone, so a
        // grant signed without the comparison having been made is a grant over whatever came up the wire.
        guard comparisonConfirmed else { throw AccountAuthorityServiceError.candidateUnverified }
        guard let granteeKey = GuaBase64URL.decode(candidate.deviceKeyB64),
              let computed = AuthorityFingerprint.of(granteeKey),
              computed == candidate.fingerprint else {
            throw AccountAuthorityServiceError.candidateUnverified
        }

        let authorityKey = try signingKey(for: state.accountID)
        guard let prevHash = AuthorityRecord.hashBytes(fromHex: state.headHash) else {
            throw AccountAuthorityServiceError.malformedServerValue
        }
        guard state.headSeq >= 0, state.headSeq < Int64.max else {
            throw AccountAuthorityServiceError.malformedServerValue
        }

        let challenge = try await client.authorityChallenge(accessToken: accessToken,
                                                            purpose: .grant,
                                                            stepUp: stepUp)
        guard let challengeBytes = GuaBase64URL.decode(challenge.challenge),
              challengeBytes.count == AuthorityRecord.challengeLength else {
            throw AccountAuthorityServiceError.malformedServerValue
        }

        let canonicalBytes = try AuthorityRecord.deviceGrant(accountID: state.accountID,
                                                             granteeKey: granteeKey,
                                                             label: candidate.label,
                                                             authorizingKey: [UInt8](authorityKey.publicKey.rawRepresentation),
                                                             prevHash: prevHash,
                                                             seq: UInt64(state.headSeq) + 1)
        try AuthorityRecord.validate(canonicalBytes)

        let preimage = try AuthorityProofs.recordPreimage(type: .deviceGrant,
                                                          challenge: challengeBytes,
                                                          canonicalBytes: canonicalBytes)
        let signature: Data
        do {
            signature = try authorityKey.signature(for: Data(preimage))
        } catch {
            throw AccountAuthorityServiceError.signingFailed
        }

        return try await client.submitAuthorityDeviceGrant(accessToken: accessToken,
                                                           record: GuaBase64URL.encode(canonicalBytes),
                                                           signature: GuaBase64URL.encode([UInt8](signature)),
                                                           challenge: challenge.challenge)
    }

    func revokeDevice(accessToken: String,
                      state: AuthorityChainState,
                      deviceKey: String,
                      reason: UInt8,
                      stepUp: AuthorityStepUp) async throws -> AuthoritySubmission {
        guard isEnabled else { throw AccountAuthorityServiceError.disabled }
        guard let removedKey = GuaBase64URL.decode(deviceKey),
              removedKey.count == AuthorityRecord.keyLength else {
            throw AccountAuthorityServiceError.malformedServerValue
        }

        let authorityKey = try signingKey(for: state.accountID)
        guard let prevHash = AuthorityRecord.hashBytes(fromHex: state.headHash),
              state.headSeq >= 0, state.headSeq < Int64.max else {
            throw AccountAuthorityServiceError.malformedServerValue
        }

        let challenge = try await client.authorityChallenge(accessToken: accessToken,
                                                            purpose: .revoke,
                                                            stepUp: stepUp)
        guard let challengeBytes = GuaBase64URL.decode(challenge.challenge),
              challengeBytes.count == AuthorityRecord.challengeLength else {
            throw AccountAuthorityServiceError.malformedServerValue
        }

        let canonicalBytes = try AuthorityRecord.deviceRevoke(accountID: state.accountID,
                                                              deviceKey: removedKey,
                                                              reason: reason,
                                                              authorizingKey: [UInt8](authorityKey.publicKey.rawRepresentation),
                                                              prevHash: prevHash,
                                                              seq: UInt64(state.headSeq) + 1)
        try AuthorityRecord.validate(canonicalBytes)

        let preimage = try AuthorityProofs.recordPreimage(type: .deviceRevoke,
                                                          challenge: challengeBytes,
                                                          canonicalBytes: canonicalBytes)
        let signature: Data
        do {
            signature = try authorityKey.signature(for: Data(preimage))
        } catch {
            throw AccountAuthorityServiceError.signingFailed
        }

        let submission = try await client.submitAuthorityDeviceRevoke(accessToken: accessToken,
                                                                      record: GuaBase64URL.encode(canonicalBytes),
                                                                      signature: GuaBase64URL.encode([UInt8](signature)),
                                                                      challenge: challenge.challenge)
        // A self-revocation that took effect immediately leaves this phone with a key the chain no longer
        // names. Dropping it here is what makes "stop trusting this phone" true on the phone as well as on
        // the chain; a pending one keeps its key, because it can still be opposed.
        if GuaBase64URL.encode([UInt8](authorityKey.publicKey.rawRepresentation)) == deviceKey,
           !submission.isPending {
            keyStore.removeKeys(forAccountID: state.accountID.value)
        }
        return submission
    }

    func oppose(accessToken: String,
                state: AuthorityChainState,
                pending: AuthorityPendingTransition,
                stepUp: AuthorityStepUp?) async throws {
        guard isEnabled else { throw AccountAuthorityServiceError.disabled }

        guard pending.type != .adoptRoot else {
            // The one case where no device can exist yet, so the session is the whole authorization. A
            // first opposition needs no factor; the server asks for one from the second onward.
            try await client.opposeAuthorityAdoption(accessToken: accessToken,
                                                     recordHash: pending.recordHash,
                                                     stepUp: stepUp)
            return
        }

        // Everything else is the claim a session cannot make, so it is a signed record from a key the chain
        // has active and unquarantined. No factor is asked for and no hold is weighed: the holds gate
        // starting a transition and never opposing one, because an owner who has just changed their PIN to
        // lock a thief out must not be the one disarmed by it.
        let authorityKey = try signingKey(for: state.accountID)
        guard let opposedHash = AuthorityRecord.hashBytes(fromHex: pending.recordHash),
              let prevHash = AuthorityRecord.hashBytes(fromHex: state.headHash),
              pending.seq >= 1 else {
            throw AccountAuthorityServiceError.malformedServerValue
        }

        let challenge = try await client.authorityChallenge(accessToken: accessToken,
                                                            purpose: .oppose,
                                                            stepUp: nil)
        guard let challengeBytes = GuaBase64URL.decode(challenge.challenge),
              challengeBytes.count == AuthorityRecord.challengeLength else {
            throw AccountAuthorityServiceError.malformedServerValue
        }

        // An Oppose takes no slot and is never appended, so it carries the seq and prevHash of the record
        // it cancels rather than the position after it.
        let canonicalBytes = try AuthorityRecord.oppose(accountID: state.accountID,
                                                        opposedRecordHash: opposedHash,
                                                        authorizingKey: [UInt8](authorityKey.publicKey.rawRepresentation),
                                                        prevHash: prevHash,
                                                        seq: UInt64(pending.seq))
        try AuthorityRecord.validate(canonicalBytes)

        let preimage = try AuthorityProofs.recordPreimage(type: .oppose,
                                                          challenge: challengeBytes,
                                                          canonicalBytes: canonicalBytes)
        let signature: Data
        do {
            signature = try authorityKey.signature(for: Data(preimage))
        } catch {
            throw AccountAuthorityServiceError.signingFailed
        }

        try await client.submitAuthorityOpposition(accessToken: accessToken,
                                                   record: GuaBase64URL.encode(canonicalBytes),
                                                   signature: GuaBase64URL.encode([UInt8](signature)),
                                                   challenge: challenge.challenge)
    }

    // MARK: - The security notification channel

    func registerSecurityAlerts(accessToken: String,
                                accountID: AccountID) async throws -> SecurityNotificationSummary {
        guard isEnabled else { throw AccountAuthorityServiceError.disabled }
        guard let token = pushTokenStore.token else { throw AccountAuthorityServiceError.noPushToken }

        let installationID: String
        do {
            installationID = try installationIDStore.installationID()
        } catch {
            throw AccountAuthorityServiceError.keyUnavailable
        }

        // The device key is bound with a signature rather than named, because the field is what makes
        // removing this row from another install need one. A claimed key would let an attacker name the
        // owner's key on their own row, and would let a row be planted that the owner's device can never
        // remove.
        var authorityDeviceKeyB64: String?
        var challengeValue: String?
        var signatureValue: String?
        if let authorityKey = try? keyStore.authorityKey(forAccountID: accountID.value) {
            let publicKey = [UInt8](authorityKey.publicKey.rawRepresentation)
            let challenge = try await client.authorityChallenge(accessToken: accessToken,
                                                                purpose: .notify,
                                                                stepUp: nil)
            guard let challengeBytes = GuaBase64URL.decode(challenge.challenge),
                  challengeBytes.count == AuthorityRecord.challengeLength else {
                throw AccountAuthorityServiceError.malformedServerValue
            }
            let preimage = try AuthorityProofs.notificationPreimage(accountID: accountID,
                                                                    installationID: installationID,
                                                                    deviceKey: publicKey,
                                                                    challenge: challengeBytes)
            do {
                signatureValue = try GuaBase64URL.encode([UInt8](authorityKey.signature(for: Data(preimage))))
            } catch {
                throw AccountAuthorityServiceError.signingFailed
            }
            authorityDeviceKeyB64 = GuaBase64URL.encode(publicKey)
            challengeValue = challenge.challenge
        }

        let registration = SecurityNotificationRegistration(installationID: installationID,
                                                            platform: Self.applePlatform,
                                                            token: token,
                                                            appID: appSettings.pusherAppID,
                                                            deviceLabel: deviceLabel,
                                                            authorityDeviceKeyB64: authorityDeviceKeyB64,
                                                            challenge: challengeValue,
                                                            signature: signatureValue)
        return try await client.registerSecurityNotification(accessToken: accessToken,
                                                             registration: registration)
    }

    func securityAlerts(accessToken: String) async throws -> [SecurityNotificationSummary] {
        guard isEnabled else { throw AccountAuthorityServiceError.disabled }
        return try await client.securityNotifications(accessToken: accessToken)
    }

    func removeSecurityAlerts(accessToken: String,
                              accountID: AccountID,
                              installationID: String,
                              stepUp: AuthorityStepUp?) async throws {
        guard isEnabled else { throw AccountAuthorityServiceError.disabled }

        let thisInstall = try? installationIDStore.installationID()
        let isThisInstall = thisInstall == installationID

        // Tier 1: this install removing its own row, which needs nothing else, because the person holding
        // this phone is the person the channel serves.
        //
        // Tier 2: another install, which needs the step-up and, where that row carries a device key, a
        // signature by **the key the row itself names**. The server verifies under that key rather than
        // under one the request chooses, so this phone's signature is accepted exactly when the row names
        // this phone's key and is refused otherwise, which is the truth and is what stops a fresh
        // post-recovery session stripping the owner's channel with the PIN it just minted.
        var challengeValue: String?
        var signatureValue: String?
        if !isThisInstall, let authorityKey = try? keyStore.authorityKey(forAccountID: accountID.value) {
            let challenge = try await client.authorityChallenge(accessToken: accessToken,
                                                                purpose: .notify,
                                                                stepUp: nil)
            guard let challengeBytes = GuaBase64URL.decode(challenge.challenge),
                  challengeBytes.count == AuthorityRecord.challengeLength else {
                throw AccountAuthorityServiceError.malformedServerValue
            }
            // The preimage names the row being removed, so a signature for one row cannot remove another.
            let preimage = try AuthorityProofs.notificationPreimage(accountID: accountID,
                                                                    installationID: installationID,
                                                                    deviceKey: [UInt8](authorityKey.publicKey.rawRepresentation),
                                                                    challenge: challengeBytes)
            do {
                signatureValue = try GuaBase64URL.encode([UInt8](authorityKey.signature(for: Data(preimage))))
            } catch {
                throw AccountAuthorityServiceError.signingFailed
            }
            challengeValue = challenge.challenge
        }

        let removal = SecurityNotificationRemoval(installationID: installationID,
                                                  callerInstallationID: thisInstall,
                                                  stepUp: isThisInstall ? nil : stepUp,
                                                  challenge: challengeValue,
                                                  signature: signatureValue)
        try await client.removeSecurityNotification(accessToken: accessToken, removal: removal)
    }

    func thisInstallationID() -> String? {
        guard isEnabled else { return nil }
        return try? installationIDStore.installationID()
    }

    /// The platform name the server's enum uses for this client.
    private static let applePlatform = "APNS"

    func liveApprovals(accessToken: String) async throws -> [AuthorityApproval] {
        guard isEnabled else { throw AccountAuthorityServiceError.disabled }
        return try await client.liveAuthorityApprovals(accessToken: accessToken)
    }

    func signApproval(accessToken: String, approval: AuthorityApproval, state: AuthorityChainState) async throws {
        guard isEnabled else { throw AccountAuthorityServiceError.disabled }

        let authorityKey = try signingKey(for: state.accountID)
        guard let approvalID = GuaBase64URL.decode(approval.approvalID),
              approvalID.count == AuthorityProofs.approvalIDLength,
              let actionDigest = GuaBase64URL.decode(approval.actionDigest),
              actionDigest.count == AuthorityRecord.hashLength,
              let challenge = GuaBase64URL.decode(approval.challenge),
              challenge.count == AuthorityRecord.challengeLength else {
            throw AccountAuthorityServiceError.malformedServerValue
        }

        let preimage = try AuthorityProofs.approvalPreimage(accountID: state.accountID,
                                                            approvalID: approvalID,
                                                            actionDigest: actionDigest,
                                                            challenge: challenge)
        let signature: Data
        do {
            signature = try authorityKey.signature(for: Data(preimage))
        } catch {
            throw AccountAuthorityServiceError.signingFailed
        }
        try await client.signAuthorityApproval(accessToken: accessToken,
                                               approvalID: approval.approvalID,
                                               signature: GuaBase64URL.encode([UInt8](signature)))
    }

    func thisDeviceKey(accountID: AccountID) -> String? {
        guard let key = try? keyStore.authorityKey(forAccountID: accountID.value) else { return nil }
        return GuaBase64URL.encode([UInt8](key.publicKey.rawRepresentation))
    }

    /// The device authority key this account's chain would name for this device.
    ///
    /// It is the same keychain item the genesis builder writes, deliberately: a class `0x01` account's
    /// genesis authority key **is** its first device key, committed by the accountId rather than by a
    /// record, so a second store would be a second answer to one question.
    private func signingKey(for accountID: AccountID) throws -> Curve25519.Signing.PrivateKey {
        do {
            return try keyStore.authorityKey(forAccountID: accountID.value)
        } catch {
            throw AccountAuthorityServiceError.notAnAuthorityDevice
        }
    }
}
