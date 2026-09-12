//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import CryptoKit
import Foundation

/// base64url without padding, the encoding identity-service uses for every genesis field on the wire.
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

/// A genesis this device registered, carried for the length of one signup and no longer.
///
/// The handle is a routing hint, not a capability: a stolen one attaches nothing and a planted one
/// fails at the proof step (ADM-008 decision 6).
struct PendingAccountGenesis: Equatable {
    let accountID: AccountID
    let attachHandle: String
    let expiresAt: Date
}

enum AccountGenesisRegistration: Equatable {
    case registered(PendingAccountGenesis)
    /// The deployment answered 503: it does not do genesis. The caller continues with today's signup,
    /// unchanged and with nothing shown to the user.
    case notSupportedByDeployment
    /// The feature flag is off, so nothing was generated, stored or sent.
    case disabled
}

enum AccountGenesisServiceError: Error {
    /// The authority key could not be created, stored or read back. A signup that meant to register a
    /// genesis must fail here rather than silently create an account with none.
    case keyUnavailable
    case signingFailed
    case malformedChallenge
    case registrationFailed(Error)
}

@MainActor
protocol AccountGenesisServiceProtocol {
    /// The feature flag. While false nothing in this file runs and both auth paths are byte-identical
    /// to what they were before it existed.
    var isEnabled: Bool { get }

    /// Generates the account authority key, registers the genesis, and returns the single-use attach
    /// handle for this signup.
    func registerGenesis() async throws -> AccountGenesisRegistration

    /// The reserved `login_hint` grammar of ADM-008 decision 6: `gua:phone=<E.164>;genesis=<handle>`.
    nonisolated func loginHint(phoneNumber: String, pending: PendingAccountGenesis) -> String

    /// Signs the fixed-length attach preimage with the committed authority key and returns the
    /// signature as base64url, for the profile step's `attachProof`.
    func attachProof(challenge: String, for pending: PendingAccountGenesis) throws -> String

    /// Drops the keys of a signup that did not complete.
    func discard(_ pending: PendingAccountGenesis)
}

/// The client half of ADM-008 Phase 3: mint an `AccountGenesis` on device, register it, carry its
/// handle through the OIDC `login_hint`, and prove possession of the committed key when the sign-in
/// page asks for it.
///
/// Nothing here changes routing or login. The accountId is not an identifier the app shows, sends
/// anywhere else, or stores beside the account: ADM-008 decision 10 keeps it out of `preferred_username`,
/// `sub` and every localpart-derived field, and the app has no reason to hold it past the signup.
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

    /// Convenience initializer for the app, returning `nil` when this build has no identity service
    /// configured (the same condition under which the phone path already fails closed).
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
        // The flag gate, ahead of anything being generated, stored or sent. Callers check `isEnabled`
        // as well; this is here so the service cannot be made to act while the flag is down.
        guard isEnabled else { return .disabled }

        let keyPair = keyStore.generateKeyPair()

        // 16 CSPRNG bytes, so two devices choosing the same keys would still get distinct ids
        // (ADM-008 decision 3). Never derived from the phone or anything else identifying.
        var entropy = [UInt8](repeating: 0, count: AccountGenesis.entropyLength)
        guard SecRandomCopyBytes(kSecRandomDefault, entropy.count, &entropy) == errSecSuccess else {
            throw AccountGenesisServiceError.keyUnavailable
        }

        let canonicalBytes = try AccountGenesis.encode(authorityPublicKey: [UInt8](keyPair.authority.publicKey.rawRepresentation),
                                                       recoveryAuthorityPublicKey: [UInt8](keyPair.recovery.publicKey.rawRepresentation),
                                                       entropy: entropy)
        // Decode what we just built before sending it: the accountId is a permanent hash of these exact
        // bytes, so a client that ships bytes its own decoder would refuse is a client minting an
        // account nobody can re-derive.
        let genesis = try AccountGenesis.decode(canonicalBytes)
        let accountID = try genesis.accountID()

        let signature: Data
        do {
            signature = try keyPair.authority.signature(for: Data(GenesisProofs.genesisProofPreimage(canonicalBytes: canonicalBytes)))
        } catch {
            throw AccountGenesisServiceError.signingFailed
        }

        // Stored before the call, so a registration that succeeds while the reply is lost still has its
        // key on this device. A registration that fails takes its keys with it, below.
        try keyStore.persist(keyPair, forAccountID: accountID.value)

        do {
            let response = try await identityServiceClient.registerAccountGenesis(genesis: GuaBase64URL.encode(canonicalBytes),
                                                                                  proof: GuaBase64URL.encode([UInt8](signature)))
            guard response.accountID == accountID.value else {
                // The server derives the accountId from the bytes it received. A disagreement means the
                // bytes changed in flight, and attaching under it would bind the wrong account.
                MXLog.error("The registered accountId does not match the one derived on device.")
                keyStore.removeKeys(forAccountID: accountID.value)
                throw AccountGenesisServiceError.registrationFailed(AccountGenesisError.badAccountID)
            }
            return .registered(PendingAccountGenesis(accountID: accountID,
                                                     attachHandle: response.attachHandle,
                                                     expiresAt: response.expiresAt))
        } catch IdentityServiceError.genesisUnavailable {
            // 503: this deployment does not do genesis. Not an error, and nothing the user should see.
            MXLog.info("Account genesis is not enabled on this deployment; continuing with the existing signup.")
            keyStore.removeKeys(forAccountID: accountID.value)
            return .notSupportedByDeployment
        } catch {
            keyStore.removeKeys(forAccountID: accountID.value)
            throw AccountGenesisServiceError.registrationFailed(error)
        }
    }

    nonisolated func loginHint(phoneNumber: String, pending: PendingAccountGenesis) -> String {
        // The grammar is strict on the server: an unparsable hint, an unknown or duplicated key and a
        // malformed handle all fail the signup rather than being quietly dropped, because dropping a
        // handle is the silent downgrade ADM-008 decision 6 forbids. The reserved bare value `passkey`
        // is a different hint entirely and is untouched by the `gua:` grammar.
        "gua:phone=\(phoneNumber);genesis=\(pending.attachHandle)"
    }

    func attachProof(challenge: String, for pending: PendingAccountGenesis) throws -> String {
        guard let challengeBytes = GuaBase64URL.decode(challenge),
              challengeBytes.count == GenesisProofs.attachChallengeLength else {
            throw AccountGenesisServiceError.malformedChallenge
        }

        let key: Curve25519.Signing.PrivateKey
        do {
            key = try keyStore.authorityKey(forAccountID: pending.accountID.value)
        } catch {
            // ADM-008 decision 6: a handle that was presented and fails to attach fails the signup.
            // Continuing here would create the silent bootstrap the decision warns about.
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
