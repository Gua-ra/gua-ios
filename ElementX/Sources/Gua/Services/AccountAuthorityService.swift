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

/// A transition inside its window, which already holds its `seq`.
struct AuthorityPendingTransition: Equatable {
    let type: String
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

/// The slice of identity-service the authority chain needs.
///
/// Narrow rather than folded into ``IdentityServiceClientProtocol``, exactly as ``AccountGenesisRegistering``
/// is: these calls exist only behind an off-by-default flag, and a screen that has no business with the
/// chain should not be handed the chain.
protocol AccountAuthorityRequesting: Sendable {
    /// Mints the challenge one transition will sign, spending the step-up in the same call so the
    /// step-up can never be older than the challenge it authorizes.
    func authorityChallenge(accessToken: String,
                            purpose: AuthorityPurpose,
                            stepUp: AuthorityStepUp) async throws -> AuthorityChallenge
    func submitAuthorityAdoption(accessToken: String,
                                 record: String,
                                 signature: String,
                                 challenge: String,
                                 recoveryArtifactConfirmed: Bool) async throws -> AuthoritySubmission
    func submitAuthorityDeviceGrant(accessToken: String,
                                    record: String,
                                    signature: String,
                                    challenge: String) async throws -> AuthoritySubmission
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
    /// The key as the user copies it: RFC 4648 base32, lowercase, unpadded, in groups of four.
    ///
    /// Base32 rather than hex or base64 because this is read off one screen and typed into something
    /// else: the alphabet the accountId already uses has no case to get wrong and no `+` or `/` to lose
    /// to an autocorrect, and 32 bytes come to 52 characters, which is 13 groups.
    static func render(_ key: Curve25519.Signing.PrivateKey) -> String {
        let encoded = GuaBase32.encode([UInt8](key.rawRepresentation))
        return stride(from: 0, to: encoded.count, by: 4).map { offset in
            let start = encoded.index(encoded.startIndex, offsetBy: offset)
            let end = encoded.index(start, offsetBy: min(4, encoded.count - offset))
            return String(encoded[start..<end])
        }
        .joined(separator: " ")
    }
}

/// An adoption that is built, signed and ready, waiting only on the user confirming they stored the
/// recovery artifact.
///
/// A class rather than a struct so the confirmation cannot be forged by a caller assembling its own
/// value: ``confirmArtifactStored()`` is the only way to set it, and it wipes the artifact from this
/// object as it does, which is what "shown once" means in code.
@MainActor
final class PreparedAdoption {
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

    init(accountID: AccountID,
         record: String,
         signature: String,
         challenge: String,
         deviceLabel: String,
         recoveryArtifact: String) {
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
}

// MARK: - The service

@MainActor
protocol AccountAuthorityServiceProtocol {
    /// The feature flag. While false nothing in this file runs.
    var isEnabled: Bool { get }

    func state(accessToken: String) async throws -> AuthorityChainState

    /// Runs everything adoption needs before the user is asked to store the recovery key: the scoped
    /// step-up and its challenge, the two keys, the record and its signature.
    ///
    /// Nothing reaches the chain here. A client that stops between this call and ``submitAdoption(accessToken:prepared:)``
    /// has produced nothing the server has seen, and its keys are garbage it replaces next time.
    func prepareAdoption(accessToken: String,
                         accountID: AccountID,
                         stepUp: AuthorityStepUp) async throws -> PreparedAdoption

    /// Submits a prepared adoption. Refuses locally while the artifact is unconfirmed.
    func submitAdoption(accessToken: String, prepared: PreparedAdoption) async throws -> AuthoritySubmission

    /// Signs a `DeviceGrant` over a key another device generated for itself, in the one direction
    /// ADM-009 decision 5 permits.
    func signDeviceGrant(accessToken: String,
                         state: AuthorityChainState,
                         granteeKey: [UInt8],
                         label: String,
                         stepUp: AuthorityStepUp) async throws -> AuthoritySubmission

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
    private let appSettings: AppSettings
    /// What a record's 16-byte label will say. Read once so a rename mid-flow cannot make the label in
    /// the signature differ from the one the screen showed.
    private let deviceLabel: String

    init(client: AccountAuthorityRequesting,
         keyStore: AccountAuthorityKeyStoreProtocol,
         appSettings: AppSettings,
         deviceLabel: String = UIDevice.current.name) {
        self.client = client
        self.keyStore = keyStore
        self.appSettings = appSettings
        self.deviceLabel = deviceLabel
    }

    /// Convenience initializer for the app, returning `nil` when this build has no identity service
    /// configured, which is the same condition under which every other Gua account screen fails closed.
    convenience init?(appSettings: AppSettings) {
        guard let client = IdentityServiceClient() else { return nil }
        self.init(client: client, keyStore: AccountAuthorityKeyStore(), appSettings: appSettings)
    }

    var isEnabled: Bool {
        appSettings.guaAccountAuthorityEnabled
    }

    func state(accessToken: String) async throws -> AuthorityChainState {
        guard isEnabled else { throw AccountAuthorityServiceError.disabled }
        return try await client.authorityState(accessToken: accessToken)
    }

    func prepareAdoption(accessToken: String,
                         accountID: AccountID,
                         stepUp: AuthorityStepUp) async throws -> PreparedAdoption {
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

        return PreparedAdoption(accountID: accountID,
                                record: GuaBase64URL.encode(canonicalBytes),
                                signature: GuaBase64URL.encode([UInt8](signature)),
                                challenge: challenge.challenge,
                                deviceLabel: AuthorityLabel.decode(AuthorityLabel.encode(deviceLabel)),
                                recoveryArtifact: AuthorityRecoveryArtifact.render(keyPair.recovery))
    }

    func submitAdoption(accessToken: String, prepared: PreparedAdoption) async throws -> AuthoritySubmission {
        guard isEnabled else { throw AccountAuthorityServiceError.disabled }
        // Adoption is unreachable without the confirmation, which is a rule rather than a prompt
        // (ADM-009 decision 7). The server refuses an unconfirmed submission as well; this is why the
        // request is never made.
        guard prepared.isArtifactConfirmed else { throw AccountAuthorityServiceError.artifactUnconfirmed }

        do {
            return try await client.submitAuthorityAdoption(accessToken: accessToken,
                                                            record: prepared.record,
                                                            signature: prepared.signature,
                                                            challenge: prepared.challenge,
                                                            recoveryArtifactConfirmed: true)
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

    func signDeviceGrant(accessToken: String,
                         state: AuthorityChainState,
                         granteeKey: [UInt8],
                         label: String,
                         stepUp: AuthorityStepUp) async throws -> AuthoritySubmission {
        guard isEnabled else { throw AccountAuthorityServiceError.disabled }

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
                                                             label: label,
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
