//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// Share link on the brand host carrying only the localpart, so the homeserver is never shown.
enum GuaUserLink {
    static func url(for userID: String) -> URL? {
        guard userID.hasPrefix("@") else { return nil }

        let localpart = userID.dropFirst().prefix { $0 != ":" }
        guard !localpart.isEmpty else { return nil }

        // The development link host can carry a port, which `URLComponents.host` rejects.
        guard var components = URLComponents(string: "https://\(GuaDeployment.current.linkHost)") else { return nil }
        components.path = "/u/\(localpart)"
        return components.url
    }
}
