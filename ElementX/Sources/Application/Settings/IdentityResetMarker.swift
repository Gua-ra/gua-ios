//
// Copyright Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// Freshness rules for the per-account identity-reset marker the app shares with the notification
/// extension through the App Group defaults.
///
/// While an identity reset holds the encryption sync, the app rewrites the marker every
/// `refreshInterval`, so a live reset never goes stale. A marker older than `maxAge` belongs to a
/// process that died mid-reset and must not keep the extension standing down. A value that is not
/// a plausible timestamp counts as absent: standing down wrongly costs one generic notification,
/// standing down forever costs every notification.
enum IdentityResetMarker {
    static let refreshInterval: Duration = .seconds(30)
    static let maxAge: TimeInterval = 180
    /// A clock adjustment can date a marker slightly in the future; beyond this it is not trusted.
    static let futureTolerance: TimeInterval = 60

    static func isFresh(startedAt: Date?, now: Date = .now) -> Bool {
        guard let startedAt else { return false }
        let age = now.timeIntervalSince(startedAt)
        return age > -futureTolerance && age < maxAge
    }
}
