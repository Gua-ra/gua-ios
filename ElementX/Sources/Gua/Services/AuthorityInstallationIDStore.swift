//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation
import KeychainAccess

/// Kept in the keychain so the id survives sign-out, and device-only so two installs never share one.
@MainActor
protocol AuthorityInstallationIDStoreProtocol {
    func installationID() throws -> String
}

enum AuthorityInstallationIDStoreError: Error, Equatable {
    case keychain(String)
}

@MainActor
final class AuthorityInstallationIDStore: AuthorityInstallationIDStoreProtocol {
    private let keychain: Keychain
    private static let key = "authorityInstallationID"

    private static let byteLength = 16

    init(service: String, accessGroup: String?) {
        let keychain = if let accessGroup {
            Keychain(service: service, accessGroup: accessGroup)
        } else {
            Keychain(service: service)
        }
        self.keychain = keychain
            .synchronizable(false)
            .accessibility(.afterFirstUnlockThisDeviceOnly)
    }

    convenience init() {
        self.init(service: KeychainControllerService.sessions.genesisID,
                  accessGroup: InfoPlistReader.main.keychainAccessGroupIdentifier)
    }

    func installationID() throws -> String {
        do {
            if let existing = try keychain.getString(Self.key), !existing.isEmpty {
                return existing
            }
        } catch {
            MXLog.error("Failed reading the installation id: \(error)")
            throw AuthorityInstallationIDStoreError.keychain(String(describing: error))
        }

        var bytes = [UInt8](repeating: 0, count: Self.byteLength)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AuthorityInstallationIDStoreError.keychain("the system CSPRNG refused")
        }
        let minted = GuaBase64URL.encode(bytes)
        do {
            try keychain.set(minted, key: Self.key)
        } catch {
            // Fail rather than register under an id the next launch cannot name.
            MXLog.error("Failed storing the installation id: \(error)")
            throw AuthorityInstallationIDStoreError.keychain(String(describing: error))
        }
        return minted
    }
}
