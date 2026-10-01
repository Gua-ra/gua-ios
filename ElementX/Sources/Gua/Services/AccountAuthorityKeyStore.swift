//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import CryptoKit
import Foundation
import KeychainAccess

struct AccountAuthorityKeyPair {
    let authority: Curve25519.Signing.PrivateKey
    let recovery: Curve25519.Signing.PrivateKey
}

enum AccountAuthorityKeyStoreError: Error, Equatable {
    case keyMissing
    case keychain(String)
}

@MainActor
protocol AccountAuthorityKeyStoreProtocol {
    func generateKeyPair() -> AccountAuthorityKeyPair
    func persist(_ keyPair: AccountAuthorityKeyPair, forAccountID accountID: String) throws
    func authorityKey(forAccountID accountID: String) throws -> Curve25519.Signing.PrivateKey
    func removeKeys(forAccountID accountID: String)
}

/// Device-only keychain storage, never synced or backed up: a lost device loses the authority key.
/// The Secure Enclave does not support Ed25519, so the keys cannot live there.
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

    convenience init() {
        self.init(service: KeychainControllerService.sessions.genesisID,
                  accessGroup: InfoPlistReader.main.keychainAccessGroupIdentifier)
    }

    func generateKeyPair() -> AccountAuthorityKeyPair {
        AccountAuthorityKeyPair(authority: Curve25519.Signing.PrivateKey(),
                                recovery: Curve25519.Signing.PrivateKey())
    }

    func persist(_ keyPair: AccountAuthorityKeyPair, forAccountID accountID: String) throws {
        do {
            try keychain.set(keyPair.authority.rawRepresentation, key: Self.authorityPrefix + accountID)
            try keychain.set(keyPair.recovery.rawRepresentation, key: Self.recoveryPrefix + accountID)
        } catch {
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
