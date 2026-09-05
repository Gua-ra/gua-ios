//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation

/// Remembers that an identity reset was started for an account and has not landed on the server.
///
/// Starting a reset is destructive before anything is approved: the SDK deletes the key backup,
/// disables secret storage and mints a brand new local identity, all before the user has seen
/// the approval page. If the approval never happens, that new identity exists only on this
/// device. The setup banner's ordinary repair path would then export it into fresh key storage
/// and report success for an identity the server has never accepted. While this marker is set,
/// that path must refuse and ask for the reset to be finished instead.
///
/// Kept in user defaults, keyed by account, so it survives the app being killed between the
/// reset starting and the approval coming back.
enum IdentityResetPendingStore {
    private static func key(for userID: String) -> String {
        "gua.identityResetPending.\(userID)"
    }

    static func isPending(for userID: String) -> Bool {
        UserDefaults.standard.bool(forKey: key(for: userID))
    }

    static func markPending(for userID: String) {
        UserDefaults.standard.set(true, forKey: key(for: userID))
    }

    static func clear(for userID: String) {
        UserDefaults.standard.removeObject(forKey: key(for: userID))
    }
}
