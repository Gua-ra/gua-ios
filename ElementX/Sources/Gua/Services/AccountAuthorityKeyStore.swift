//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import CryptoKit
import Foundation
import KeychainAccess

/// The two Ed25519 keys an `AccountGenesis` commits: the account authority key, and the recovery
/// authority key that recovery-policy transitions will later be authorized under (ADM-008 decision 4).
///
/// They are distinct keys, which the codec enforces on the way in as well: a genesis whose two keys are
/// equal is refused with `duplicate_keys`.
struct AccountAuthorityKeyPair {
    let authority: Curve25519.Signing.PrivateKey
    let recovery: Curve25519.Signing.PrivateKey
}

enum AccountAuthorityKeyStoreError: Error, Equatable {
    /// No authority key is stored for this accountId. The signup that registered the genesis must fail
    /// rather than quietly fall back to a bootstrap account (ADM-008 decision 6).
    case keyMissing
    case keychain(String)
}

@MainActor
protocol AccountAuthorityKeyStoreProtocol {
    /// Generates a fresh authority and recovery key pair. Nothing is stored until ``persist(_:forAccountID:)``.
    func generateKeyPair() -> AccountAuthorityKeyPair
    func persist(_ keyPair: AccountAuthorityKeyPair, forAccountID accountID: String) throws
    func authorityKey(forAccountID accountID: String) throws -> Curve25519.Signing.PrivateKey
    func removeKeys(forAccountID accountID: String)
}

/// Device-only storage for the account authority and recovery keys.
///
/// ADM-008 decision 5 requires these to stay device-only and non-synced, and its Consequences section
/// accepts what follows: they are unescrowed, so a lost device loses authority. The store therefore
/// keeps them in the keychain under `whenUnlockedThisDeviceOnly`, which never rides iCloud Keychain and
/// never lands in an encrypted device backup, with `synchronizable` explicitly off. This is deliberately
/// the opposite of `KeychainController.recoveryKeychain`, whose whole point is to sync.
///
/// The keys are never written to disk by this app, never logged, and never leave this store: callers
/// receive a signing key to sign one fixed-length preimage with, not raw key bytes.
///
/// On the hardware question: an Ed25519 key cannot be Secure-Enclave-resident on iOS, because the
/// Enclave holds P-256 only. Suite 0x01 is Ed25519 (ADM-008 decision 5), and the same decision reserves
/// the suite byte for a hardware-resident P-256 suite, which is where non-extractability arrives. Until
/// then the guarantee this store makes is the one the keychain can actually keep: generated on device,
/// never synced, never backed up, never written anywhere else.
@MainActor
final class AccountAuthorityKeyStore: AccountAuthorityKeyStoreProtocol {
    private let keychain: Keychain

    private static let authorityPrefix = "genesisAuthority."
    private static let recoveryPrefix = "genesisRecovery."

    init(service: String, accessGroup: String?) {
        let keychain = if let accessGroup {
            Keychain(service: service, accessGroup: accessGroup)
        } else {
            Keychain(service: service)
        }
        self.keychain = keychain
            .synchronizable(false)
            .accessibility(.whenUnlockedThisDeviceOnly)
    }

    /// The store the app uses, keyed to this build's bundle identifier like every other Gua keychain.
    convenience init() {
        self.init(service: KeychainControllerService.sessions.genesisID,
                  accessGroup: InfoPlistReader.main.keychainAccessGroupIdentifier)
    }

    func generateKeyPair() -> AccountAuthorityKeyPair {
        // CryptoKit seeds both from the system CSPRNG. Two independent keys are overwhelmingly distinct;
        // the codec refuses a genesis whose keys are equal, so a freak collision fails closed rather
        // than committing one key in both roles.
        AccountAuthorityKeyPair(authority: Curve25519.Signing.PrivateKey(),
                                recovery: Curve25519.Signing.PrivateKey())
    }

    func persist(_ keyPair: AccountAuthorityKeyPair, forAccountID accountID: String) throws {
        do {
            try keychain.set(keyPair.authority.rawRepresentation, key: Self.authorityPrefix + accountID)
            try keychain.set(keyPair.recovery.rawRepresentation, key: Self.recoveryPrefix + accountID)
        } catch {
            // The error is logged, the key material never is.
            MXLog.error("Failed storing the account authority key pair: \(error)")
            throw AccountAuthorityKeyStoreError.keychain(String(describing: error))
        }
    }

    func authorityKey(forAccountID accountID: String) throws -> Curve25519.Signing.PrivateKey {
        let data: Data?
        do {
            data = try keychain.getData(Self.authorityPrefix + accountID)
        } catch {
            MXLog.error("Failed reading the account authority key: \(error)")
            throw AccountAuthorityKeyStoreError.keychain(String(describing: error))
        }
        guard let data else { throw AccountAuthorityKeyStoreError.keyMissing }
        do {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        } catch {
            MXLog.error("The stored account authority key is unreadable.")
            throw AccountAuthorityKeyStoreError.keyMissing
        }
    }

    func removeKeys(forAccountID accountID: String) {
        do {
            try keychain.remove(Self.authorityPrefix + accountID)
            try keychain.remove(Self.recoveryPrefix + accountID)
        } catch {
            MXLog.error("Failed removing the account authority key pair: \(error)")
        }
    }
}
