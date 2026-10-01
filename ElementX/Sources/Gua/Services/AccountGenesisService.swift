//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import CryptoKit
import Foundation

/// Unpadded base64url, the wire encoding of every genesis field.
enum GuaBase64URL {
    static func encode(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ value: String) -> [UInt8]? {
        var padded = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = padded.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { padded += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: padded) else { return nil }
        return [UInt8](data)
    }
}

/// The attach handle is only a routing hint; attaching requires the proof signature.
struct PendingAccountGenesis: Equatable {
    let accountID: AccountID
    let attachHandle: String
    let expiresAt: Date

    /// Mirrors the server's handle validation: a malformed handle fails the whole authorize request.
    static func isValidAttachHandle(_ value: String) -> Bool {
        guard (16...128).contains(value.count) else { return false }
        return value.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_")
        }
    }

    func isUsable(at date: Date = Date()) -> Bool {
        expiresAt > date
    }
}

enum AccountGenesisRegistration: Equatable {
    case registered(PendingAccountGenesis)
    /// No genesis is issued (503 or 403); the signup continues without one.
    case notSupportedByDeployment
    case disabled
}

enum AccountGenesisServiceError: Error {
    case keyUnavailable
    case signingFailed
    case malformedChallenge
    case malformedAttachHandle
    case handleExpired
    case registrationFailed(Error)
}

@MainActor
protocol AccountGenesisServiceProtocol {
    var isEnabled: Bool { get }

    func registerGenesis() async throws -> AccountGenesisRegistration

    nonisolated func loginHint(phoneNumber: String, pending: PendingAccountGenesis) -> String

    func attachProof(challenge: String, for pending: PendingAccountGenesis) throws -> String

    /// Call on every abandoned signup: the keys are filed under an accountId only the pending signup knows.
    func discard(_ pending: PendingAccountGenesis)
}

@MainActor
final class AccountGenesisService: AccountGenesisServiceProtocol {
    private let identityServiceClient: AccountGenesisRegistering
    private let keyStore: AccountAuthorityKeyStoreProtocol
    private let appSettings: AppSettings

    init(identityServiceClient: AccountGenesisRegistering,
         keyStore: AccountAuthorityKeyStoreProtocol,
         appSettings: AppSettings) {
        self.identityServiceClient = identityServiceClient
        self.keyStore = keyStore
        self.appSettings = appSettings
    }

    convenience init?(appSettings: AppSettings) {
        guard let client = IdentityServiceClient() else { return nil }
        self.init(identityServiceClient: client,
                  keyStore: AccountAuthorityKeyStore(),
                  appSettings: appSettings)
    }

    var isEnabled: Bool {
        appSettings.guaAccountGenesisEnabled
    }

    func registerGenesis() async throws -> AccountGenesisRegistration {
        guard isEnabled else { return .disabled }

        let keyPair = keyStore.generateKeyPair()

        var entropy = [UInt8](repeating: 0, count: AccountGenesis.entropyLength)
        guard SecRandomCopyBytes(kSecRandomDefault, entropy.count, &entropy) == errSecSuccess else {
            throw AccountGenesisServiceError.keyUnavailable
        }

        let canonicalBytes = try AccountGenesis.encode(authorityPublicKey: [UInt8](keyPair.authority.publicKey.rawRepresentation),
                                                       recoveryAuthorityPublicKey: [UInt8](keyPair.recovery.publicKey.rawRepresentation),
                                                       entropy: entropy)
        // Round-trip through the decoder so the client never registers bytes it would itself refuse.
        let genesis = try AccountGenesis.decode(canonicalBytes)
        let accountID = try genesis.accountID()

        let signature: Data
        do {
            signature = try keyPair.authority.signature(for: Data(GenesisProofs.genesisProofPreimage(canonicalBytes: canonicalBytes)))
        } catch {
            throw AccountGenesisServiceError.signingFailed
        }

        // Persist before registering, so a lost reply cannot leave a registered genesis without its key.
        try keyStore.persist(keyPair, forAccountID: accountID.value)

        do {
            let response = try await identityServiceClient.registerAccountGenesis(genesis: GuaBase64URL.encode(canonicalBytes),
                                                                                  proof: GuaBase64URL.encode([UInt8](signature)))
            guard response.accountID == accountID.value else {
                MXLog.error("The registered accountId does not match the one derived on device.")
                keyStore.removeKeys(forAccountID: accountID.value)
                throw AccountGenesisServiceError.registrationFailed(AccountGenesisError.badAccountID)
            }
            guard PendingAccountGenesis.isValidAttachHandle(response.attachHandle) else {
                MXLog.error("The registered attach handle is not a well-formed value.")
                keyStore.removeKeys(forAccountID: accountID.value)
                throw AccountGenesisServiceError.malformedAttachHandle
            }
            let pending = PendingAccountGenesis(accountID: accountID,
                                                attachHandle: response.attachHandle,
                                                expiresAt: response.expiresAt)
            guard pending.isUsable() else {
                MXLog.error("The registered attach handle is already outside its window.")
                keyStore.removeKeys(forAccountID: accountID.value)
                throw AccountGenesisServiceError.handleExpired
            }
            return .registered(pending)
        } catch IdentityServiceError.genesisUnavailable, IdentityServiceError.genesisIssuanceNotPermitted {
            MXLog.info("This deployment issues no account genesis; continuing with the existing signup.")
            keyStore.removeKeys(forAccountID: accountID.value)
            return .notSupportedByDeployment
        } catch let error as AccountGenesisServiceError {
            // Already cleaned up where it was raised.
            throw error
        } catch {
            keyStore.removeKeys(forAccountID: accountID.value)
            throw AccountGenesisServiceError.registrationFailed(error)
        }
    }

    nonisolated func loginHint(phoneNumber: String, pending: PendingAccountGenesis) -> String {
        // Neither value can contain `;` or `=`: the handle alphabet is validated at registration and the phone is E.164.
        "gua:phone=\(phoneNumber);genesis=\(pending.attachHandle)"
    }

    func attachProof(challenge: String, for pending: PendingAccountGenesis) throws -> String {
        guard pending.isUsable() else {
            throw AccountGenesisServiceError.handleExpired
        }

        guard let challengeBytes = GuaBase64URL.decode(challenge),
              challengeBytes.count == GenesisProofs.attachChallengeLength else {
            throw AccountGenesisServiceError.malformedChallenge
        }

        let key: Curve25519.Signing.PrivateKey
        do {
            key = try keyStore.authorityKey(forAccountID: pending.accountID.value)
        } catch {
            // A presented handle that fails to attach must fail the signup.
            throw AccountGenesisServiceError.keyUnavailable
        }

        let preimage = try GenesisProofs.attachProofPreimage(challenge: challengeBytes, accountID: pending.accountID)
        do {
            return try GuaBase64URL.encode([UInt8](key.signature(for: Data(preimage))))
        } catch {
            throw AccountGenesisServiceError.signingFailed
        }
    }

    func discard(_ pending: PendingAccountGenesis) {
        keyStore.removeKeys(forAccountID: pending.accountID.value)
    }
}
