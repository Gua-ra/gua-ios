//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// Store a checkpoint only after its consistency proof verifies, or a rewritten log goes undetected.
protocol ResolverCheckpointStoring: Sendable {
    func checkpoint(for baseURL: URL) throws -> RosterLogCheckpoint?
    func store(_ checkpoint: RosterLogCheckpoint, for baseURL: URL) throws
}

final class UserDefaultsResolverCheckpointStore: ResolverCheckpointStoring, @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func checkpoint(for baseURL: URL) throws -> RosterLogCheckpoint? {
        guard let data = defaults.data(forKey: key(for: baseURL)) else { return nil }
        return try JSONDecoder().decode(RosterLogCheckpoint.self, from: data)
    }

    func store(_ checkpoint: RosterLogCheckpoint, for baseURL: URL) throws {
        try defaults.set(JSONEncoder().encode(checkpoint), forKey: key(for: baseURL))
    }

    private func key(for baseURL: URL) -> String {
        "guaResolverLogCheckpoint.\(baseURL.absoluteString)"
    }
}
