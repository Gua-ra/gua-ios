//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import CryptoKit
import Foundation
import UIKit

// MARK: - Wire objects

enum AuthorityPurpose: String, Equatable {
    case adopt = "ADOPT"
    case grant = "GRANT"
    case revoke = "REVOKE"
    case recover = "RECOVER"
    case approve = "APPROVE"
    case oppose = "OPPOSE"
    case notify = "NOTIFY"

    var canTakeAWebStepUp: Bool {
        switch self {
        case .adopt, .grant, .revoke, .recover: true
        case .approve, .oppose, .notify: false
        }
    }
}

/// There is deliberately no phone-code case: possession of the number must never grant account authority.
enum AuthorityStepUp: Equatable {
    case passkey(stepUpID: String, assertion: PasskeyAssertion)
    case pin(String)
    /// The factor was presented in the web sheet. The server holds the proof, so the request carries none.
    case webSheet
}

struct AuthorityChallenge: Equatable {
    let challenge: String
    let expiresAt: Date
}

struct AuthoritySubmission: Equatable {
    let seq: Int64
    let isPending: Bool
    let effectiveAt: Date
    let recordHash: String
}

enum AuthorityAccountClass: Equatable {
    case bootstrap
    case genesis
    case unknown(String)

    init(wireValue: String) {
        switch wireValue {
        case "BOOTSTRAP": self = .bootstrap
        case "GENESIS": self = .genesis
        default: self = .unknown(wireValue)
        }
    }
}

enum AuthorityChainStateName: Equatable {
    case bootstrap
    case adoptionPending
    case rooted
    case recoveryPending
    /// Rooted with no active device and no recovery key. Terminal.
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

struct AuthorityDeviceSummary: Equatable, Identifiable {
    let deviceKey: String
    let label: String
    let state: AuthorityDeviceState
    let quarantineUntil: Date?
    let grantedSeq: Int64

    var id: String {
        deviceKey
    }
}

enum AuthorityPendingType: Equatable {
    case adoptRoot
    case deviceGrant
    case deviceRevoke
    case authorityRecovery
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

    /// A session alone may oppose only an adoption. Anything else needs a signature from an active device.
    var needsADeviceToOppose: Bool {
        self != .adoptRoot
    }
}

struct AuthorityPendingTransition: Equatable {
    let type: AuthorityPendingType
    let seq: Int64
    let effectiveAt: Date
    let recordHash: String
    /// Hash of the record before this one, which an `Oppose` signs. Not `AuthorityChainState.headHash`: while a record is pending, the head is that record.
    let prevHash: String?

    init(type: AuthorityPendingType, seq: Int64, effectiveAt: Date, recordHash: String, prevHash: String? = nil) {
        self.type = type
        self.seq = seq
        self.effectiveAt = effectiveAt
        self.recordHash = recordHash
        self.prevHash = prevHash
    }
}

struct AuthorityChainState: Equatable {
    let accountID: AccountID
    let accountClass: AuthorityAccountClass
    let state: AuthorityChainStateName
    let headSeq: Int64
    let headHash: String
    let devices: [AuthorityDeviceSummary]
    let pending: AuthorityPendingTransition?

    var canAdopt: Bool {
        accountClass == .bootstrap && state == .bootstrap && headSeq == 0 && pending == nil
    }

    var canRecoverThroughAccountRecovery: Bool {
        accountClass != .genesis && state != .bootstrap && pending == nil
    }

    var unquarantinedActiveDevices: [AuthorityDeviceSummary] {
        devices.filter { $0.state == .active }
    }
}

struct AuthorityApproval: Equatable, Identifiable {
    let approvalID: String
    let code: String
    let action: String?
    let actionDigest: String
    let challenge: String
    let expiresAt: Date

    var id: String {
        approvalID
    }
}

struct AuthorityCandidate: Equatable, Identifiable {
    let deviceKeyB64: String
    /// Server-computed and never shown: the client recomputes it from the key.
    let fingerprint: String
    let label: String
    let expiresAt: Date

    var id: String {
        deviceKeyB64
    }
}

struct SecurityNotificationRegistration: Equatable {
    let installationID: String
    let platform: String
    let token: String
    let appID: String
    let deviceLabel: String?
    let authorityDeviceKeyB64: String?
    let challenge: String?
    let signature: String?
}

struct SecurityNotificationSummary: Equatable, Identifiable {
    let installationID: String
    let platform: String
    let deviceLabel: String
    let tokenFingerprint: String
    let isBoundToAnAuthorityDevice: Bool
    let lastSeenAt: Date

    var id: String {
        installationID
    }
}

struct SecurityNotificationRemoval: Equatable {
    let installationID: String
    let stepUp: AuthorityStepUp?
    let challenge: String?
    let signature: String?
}

protocol AccountAuthorityRequesting: Sendable {
    func authorityChallenge(accessToken: String,
                            purpose: AuthorityPurpose,
                            stepUp: AuthorityStepUp?) async throws -> AuthorityChallenge
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
    func opposeAuthorityAdoption(accessToken: String,
                                 recordHash: String?,
                                 stepUp: AuthorityStepUp?) async throws
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

/// The format is shared by every client and pinned in `authority-vectors.v1.json`.
enum AuthorityRecoveryArtifact {
    static let prefix = "gua-recovery-1"

    static func render(_ key: Curve25519.Signing.PrivateKey) -> String {
        let encoded = GuaBase32.encode([UInt8](key.rawRepresentation))
        let groups = stride(from: 0, to: encoded.count, by: 4).map { offset in
            let start = encoded.index(encoded.startIndex, offsetBy: offset)
            let end = encoded.index(start, offsetBy: min(4, encoded.count - offset))
            return String(encoded[start..<end])
        }
        return ([prefix] + groups).joined(separator: " ")
    }

    static let keyLength = AuthorityRecord.keyLength
    static let encodedLength = 52

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

    static func looksComplete(_ typed: String) -> Bool {
        body(of: typed)?.count == encodedLength
    }

    private static func body(of typed: String) -> String? {
        let tokens = foldingASCIICase(typed).split(whereSeparator: \.isWhitespace)
        guard let first = tokens.first, String(first) == prefix else { return nil }
        return tokens.dropFirst().joined()
    }

    /// ASCII only: `lowercased()` would also fold other scalars, such as the Kelvin sign, onto alphabet letters.
    private static func foldingASCIICase(_ value: String) -> String {
        String(value.map { character in
            character.isASCII && ("A"..."Z").contains(character) ? Character(character.lowercased()) : character
        })
    }
}

/// A class so that `confirmArtifactStored()` is the only way to mark the artifact stored. It also wipes the artifact.
@MainActor
final class PreparedAuthorityRecord {
    enum Kind: Equatable {
        case adoption
        case recoveryUnderRecoveryKey
        case recoveryThroughAccountRecovery
    }

    let kind: Kind
    let accountID: AccountID
    let record: String
    let signature: String
    let challenge: String
    let deviceLabel: String

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

    func confirmArtifactStored() {
        isArtifactConfirmed = true
        recoveryArtifact = nil
    }
}

// MARK: - Errors

enum AccountAuthorityServiceError: Error, Equatable {
    case disabled
    case artifactUnconfirmed
    case keyUnavailable
    case signingFailed
    case malformedServerValue
    case notAnAuthorityDevice
    case artifactMalformed
    case artifactNotThisAccount
    case candidateUnverified
    case noPushToken
}

// MARK: - The service

@MainActor
protocol AccountAuthorityServiceProtocol {
    var isEnabled: Bool { get }

    func state(accessToken: String) async throws -> AuthorityChainState

    func webStepUpURL(accessToken: String, purpose: AuthorityPurpose) async throws -> URL

    func prepareAdoption(accessToken: String,
                         accountID: AccountID,
                         stepUp: AuthorityStepUp) async throws -> PreparedAuthorityRecord

    func prepareRecovery(accessToken: String,
                         state: AuthorityChainState,
                         typedArtifact: String,
                         stepUp: AuthorityStepUp) async throws -> PreparedAuthorityRecord

    func prepareRecoveryThroughAccountRecovery(accessToken: String,
                                               state: AuthorityChainState,
                                               stepUp: AuthorityStepUp) async throws -> PreparedAuthorityRecord

    func submit(accessToken: String, prepared: PreparedAuthorityRecord) async throws -> AuthoritySubmission

    func offerThisDevice(accessToken: String, state: AuthorityChainState) async throws -> AuthorityCandidate

    func candidates(accessToken: String) async throws -> [AuthorityCandidate]

    func signDeviceGrant(accessToken: String,
                         state: AuthorityChainState,
                         candidate: AuthorityCandidate,
                         comparisonConfirmed: Bool,
                         stepUp: AuthorityStepUp) async throws -> AuthoritySubmission

    func revokeDevice(accessToken: String,
                      state: AuthorityChainState,
                      deviceKey: String,
                      reason: UInt8,
                      stepUp: AuthorityStepUp) async throws -> AuthoritySubmission

    func oppose(accessToken: String,
                state: AuthorityChainState,
                pending: AuthorityPendingTransition,
                stepUp: AuthorityStepUp?) async throws

    func registerSecurityAlerts(accessToken: String,
                                accountID: AccountID) async throws -> SecurityNotificationSummary

    func securityAlerts(accessToken: String) async throws -> [SecurityNotificationSummary]

    func removeSecurityAlerts(accessToken: String,
                              accountID: AccountID,
                              installationID: String,
                              stepUp: AuthorityStepUp) async throws

    func thisInstallationID() -> String?

    func liveApprovals(accessToken: String) async throws -> [AuthorityApproval]

    func signApproval(accessToken: String, approval: AuthorityApproval, state: AuthorityChainState) async throws

    func thisDeviceKey(accountID: AccountID) -> String?
}

@MainActor
final class AccountAuthorityService: AccountAuthorityServiceProtocol {
    private let client: AccountAuthorityRequesting
    private let keyStore: AccountAuthorityKeyStoreProtocol
    private let installationIDStore: AuthorityInstallationIDStoreProtocol
    private let pushTokenStore: AuthorityPushTokenStore
    private let appSettings: AppSettings
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
        guard purpose.canTakeAWebStepUp else {
            throw IdentityServiceError.authority(.stepUpSheetPurposeRefused)
        }
        return try await client.startAuthorityWebStepUp(accessToken: accessToken,
                                                        purpose: purpose,
                                                        redirectURI: appSettings.oidcRedirectURL.absoluteString)
    }

    func prepareAdoption(accessToken: String,
                         accountID: AccountID,
                         stepUp: AuthorityStepUp) async throws -> PreparedAuthorityRecord {
        guard isEnabled else { throw AccountAuthorityServiceError.disabled }

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

        // Persist the keys before submitting: an accepted adoption whose reply is lost must still find its key here.
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
            // Only a definite refusal drops the keys. After a transport failure the record may have been accepted.
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

        // Parse before minting a challenge: a refused recovery submission costs the owner a cooldown.
        let recoveryKey = try AuthorityRecoveryArtifact.parse(typedArtifact)
        let recoveryPublicKey = [UInt8](recoveryKey.publicKey.rawRepresentation)
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
        return try await prepareRecoveryRecord(accessToken: accessToken,
                                               state: state,
                                               authorization: AuthorityRecord.authorizationAccountRecovery,
                                               signWith: nil,
                                               authorizingKey: AuthorityRecord.zeroKey,
                                               stepUp: stepUp)
    }

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
            signature = try (committedRecoveryKey ?? keyPair.authority).signature(for: Data(preimage))
        } catch {
            throw AccountAuthorityServiceError.signingFailed
        }

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

        // A key the chain already names is never offered again: re-admitting a revoked key would undo the revocation.
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
            try await client.opposeAuthorityAdoption(accessToken: accessToken,
                                                     recordHash: pending.recordHash,
                                                     stepUp: stepUp)
            return
        }

        let authorityKey = try signingKey(for: state.accountID)
        guard let opposedHash = AuthorityRecord.hashBytes(fromHex: pending.recordHash),
              let pendingPrevHash = pending.prevHash,
              let prevHash = AuthorityRecord.hashBytes(fromHex: pendingPrevHash),
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
                              stepUp: AuthorityStepUp) async throws {
        guard isEnabled else { throw AccountAuthorityServiceError.disabled }

        // The server verifies the signature under the key the row names, so this device can only remove a row bound to its own key.
        var challengeValue: String?
        var signatureValue: String?
        if let authorityKey = try? keyStore.authorityKey(forAccountID: accountID.value) {
            let challenge = try await client.authorityChallenge(accessToken: accessToken,
                                                                purpose: .notify,
                                                                stepUp: nil)
            guard let challengeBytes = GuaBase64URL.decode(challenge.challenge),
                  challengeBytes.count == AuthorityRecord.challengeLength else {
                throw AccountAuthorityServiceError.malformedServerValue
            }
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
                                                  stepUp: stepUp,
                                                  challenge: challengeValue,
                                                  signature: signatureValue)
        try await client.removeSecurityNotification(accessToken: accessToken, removal: removal)
    }

    func thisInstallationID() -> String? {
        guard isEnabled else { return nil }
        return try? installationIDStore.installationID()
    }

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

    /// The same keychain item account genesis writes: a genesis authority key is the account's first device key.
    private func signingKey(for accountID: AccountID) throws -> Curve25519.Signing.PrivateKey {
        do {
            return try keyStore.authorityKey(forAccountID: accountID.value)
        } catch {
            throw AccountAuthorityServiceError.notAnAuthorityDevice
        }
    }
}
