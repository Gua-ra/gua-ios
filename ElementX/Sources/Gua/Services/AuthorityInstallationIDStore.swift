//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation
import KeychainAccess

/// This install's own identifier, which the security-notification channel of ADM-009 gate 2 is keyed on.
///
/// **Why the keychain and not user defaults.** The channel's whole property is that it survives what an
/// account recovery destroys: completing one deletes every passkey, sets a caller-chosen PIN and revokes
/// every session in one transaction. A registration keyed on anything a sign-out clears would die with the
/// sessions, which is why a Matrix pusher cannot carry this: a pusher lives under a session. The nearest
/// thing this app already had is `pusherProfileTag`, 16 random characters in user defaults, which is the
/// wrong store: it is app data, not a security identifier, and it is gone with the app's container.
///
/// **What it is not.** It is not an account identifier and it is not derived from one. It names this
/// install of this app on this phone, nothing else, and the server uses it as the upsert key for one row
/// and as the thing a removal names.
///
/// **What it costs.** It is a per-install identifier deliberately persisted across sign-outs, so it
/// correlates one account to one physical device over time. That is a departure from everything else this
/// app stores and it belongs in the privacy copy rather than staying an implementation detail. It is
/// generated locally, never leaves the device except in the registration and removal calls, and is never
/// logged.
@MainActor
protocol AuthorityInstallationIDStoreProtocol {
    /// This install's id, minted on first read and stable afterwards.
    func installationID() throws -> String
}

enum AuthorityInstallationIDStoreError: Error, Equatable {
    case keychain(String)
}

@MainActor
final class AuthorityInstallationIDStore: AuthorityInstallationIDStoreProtocol {
    private let keychain: Keychain
    private static let key = "authorityInstallationID"

    /// 16 bytes, base64url: long enough that two installs never collide, short enough to be an opaque
    /// name in a request rather than something a reader is tempted to interpret.
    private static let byteLength = 16

    init(service: String, accessGroup: String?) {
        let keychain = if let accessGroup {
            Keychain(service: service, accessGroup: accessGroup)
        } else {
            Keychain(service: service)
        }
        self.keychain = keychain
            .synchronizable(false)
            // Device-only, for the same reason the authority keys are: an id that rode iCloud Keychain to
            // the account's other phones would name two installs the same and make one row removable from
            // a device the owner did not think was holding it.
            .accessibility(.afterFirstUnlockThisDeviceOnly)
    }

    /// The store the app uses. The same keychain service as the authority keys, which is the one this app
    /// has that a sign-out does not clear.
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
            // Returning the value anyway would register a row under an id the next launch cannot name,
            // which is a registration the owner's own device could never remove.
            MXLog.error("Failed storing the installation id: \(error)")
            throw AuthorityInstallationIDStoreError.keychain(String(describing: error))
        }
        return minted
    }
}
