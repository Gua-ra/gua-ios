//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation

/// The APNs device token of this launch, so the security-notification channel can be registered from the
/// account screen rather than from the push path.
///
/// **Why it exists at all.** The token arrives once, in the app delegate's registration callback, and the
/// only thing that consumed it was the Matrix pusher. The security channel of ADM-009 gate 2 needs the same
/// token for a different destination, and it needs it at the moment the account holder asks for alerts,
/// which is not when the callback fires.
///
/// **Why in memory.** iOS hands the token to the app on every launch while notifications are authorized, so
/// a launch that has one has it early, and a launch that has none has nothing to register: the screen says
/// so rather than registering something stale. A token written to disk would outlive the permission it came
/// from and could name a destination this install no longer holds.
///
/// Empty until the push registration callback runs, and empty for good while `enableNotifications` or the
/// system permission is off. A caller reads `token` and offers nothing when it is `nil`.
@MainActor
final class AuthorityPushTokenStore {
    /// One per process, because the token is a property of the process and the two readers are wired up in
    /// different halves of the app: the push path writes it, the account screen reads it.
    static let shared = AuthorityPushTokenStore()

    /// The token as APNs gave it, hex, which is the form the push services expect.
    private(set) var token: String?

    init(token: String? = nil) {
        self.token = token
    }

    func store(deviceToken: Data) {
        token = deviceToken.map { String(format: "%02x", $0) }.joined()
    }
}
