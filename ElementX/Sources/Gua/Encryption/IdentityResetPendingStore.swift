//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation

/// Set while an identity reset has started but is not yet approved. The SDK has already replaced
/// the local identity by then, so key-storage repair must refuse until the reset finishes.
/// Kept in user defaults, keyed by account, so it survives the app being killed in between.
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
