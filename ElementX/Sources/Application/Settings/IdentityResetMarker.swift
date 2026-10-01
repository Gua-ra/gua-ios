//
// Copyright Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// Freshness of the identity-reset marker shared with the notification extension.
/// A marker older than `maxAge` belongs to a reset that died and is ignored.
enum IdentityResetMarker {
    static let refreshInterval: Duration = .seconds(30)
    static let maxAge: TimeInterval = 180
    static let futureTolerance: TimeInterval = 60

    static func isFresh(startedAt: Date?, now: Date = .now) -> Bool {
        guard let startedAt else { return false }
        let age = now.timeIntervalSince(startedAt)
        return age > -futureTolerance && age < maxAge
    }
}
