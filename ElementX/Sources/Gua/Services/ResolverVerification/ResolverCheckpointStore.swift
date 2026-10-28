//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// The last transparency-log checkpoint this install accepted, per resolver base URL. It moves forward only
/// after a consistency proof verified, so a rewritten history is caught against it.
protocol ResolverCheckpointStoring: Sendable {
    func checkpoint(for baseURL: URL) -> RosterLogCheckpoint?
    func store(_ checkpoint: RosterLogCheckpoint, for baseURL: URL)
}

final class UserDefaultsResolverCheckpointStore: ResolverCheckpointStoring, @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func checkpoint(for baseURL: URL) -> RosterLogCheckpoint? {
        guard let data = defaults.data(forKey: key(for: baseURL)) else { return nil }
        return try? JSONDecoder().decode(RosterLogCheckpoint.self, from: data)
    }

    func store(_ checkpoint: RosterLogCheckpoint, for baseURL: URL) {
        guard let data = try? JSONEncoder().encode(checkpoint) else { return }
        defaults.set(data, forKey: key(for: baseURL))
    }

    private func key(for baseURL: URL) -> String {
        "guaResolverLogCheckpoint.\(baseURL.absoluteString)"
    }
}
