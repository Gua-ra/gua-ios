//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// Builds the user-facing share link for a Gua account. It lives on the brand host and carries
/// only the localpart, so the homeserver is never shown:
///
///     @alice:dev.local  ->  https://gua.global/u/alice
///
/// Only for sharing and inviting. In-app mention parsing and pills still use `matrix.to`.
enum GuaUserLink {
    /// Builds `https://<brandHost>/u/<localpart>` for a Matrix user ID. Returns `nil` for a malformed ID.
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
