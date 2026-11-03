//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation

/// In memory only: a token on disk could outlive the notification permission it came from.
@MainActor
final class AuthorityPushTokenStore {
    static let shared = AuthorityPushTokenStore()

    private(set) var token: String?

    init(token: String? = nil) {
        self.token = token
    }

    func store(deviceToken: Data) {
        token = deviceToken.map { String(format: "%02x", $0) }.joined()
    }
}
