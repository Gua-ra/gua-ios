//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// Absent means `global`. Unrecognized values are not discoverable, so an older client never widens a stricter policy.
enum RosterSearchVisibility: Equatable {
    case global
    case group
    case server
    case unrecognized(String)

    init(rawValue: String?) {
        switch rawValue?.lowercased() {
        case nil, "global": self = .global
        case "group": self = .group
        case "server": self = .server
        case let .some(other): self = .unrecognized(other)
        }
    }
}

enum FederatedUserSearch {
    static func bareHandle(from query: String) -> String? {
        var handle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !handle.contains(":") else { return nil }
        if handle.hasPrefix("@") {
            handle = String(handle.dropFirst())
        }
        guard handle.range(of: "^[a-z0-9._=/-]{3,}$", options: .regularExpression) != nil else { return nil }
        return handle
    }

    /// Includes the searcher's own server, because Synapse's directory search only returns users who already share a room.
    static func candidates(forHandle handle: String, roster: FederationRoster, ownServerName: String) -> [String] {
        let ownGroups = Set(roster.entries.first { $0.homeserver.serverName == ownServerName }?.homeserver.searchGroups ?? [])

        let federated = roster.entries
            .filter { entry in
                guard entry.isActive, entry.homeserver.serverName != ownServerName else { return false }
                switch RosterSearchVisibility(rawValue: entry.homeserver.searchVisibility) {
                case .global:
                    return true
                case .group:
                    return !ownGroups.isDisjoint(with: entry.homeserver.searchGroups ?? [])
                case .server, .unrecognized:
                    return false
                }
            }
            .map { "@\(handle):\($0.homeserver.serverName)" }

        return ["@\(handle):\(ownServerName)"] + federated
    }
}

// MARK: - Roster cache

protocol FederationRosterProviding: Sendable {
    func currentRoster() async -> FederationRoster?
}

actor FederationRosterCache: FederationRosterProviding {
    static let shared = FederationRosterCache()

    private let fetcher: FederationRosterFetching?
    private let timeToLive: TimeInterval
    private var cached: (roster: FederationRoster, fetchedAt: Date)?

    init(fetcher: FederationRosterFetching? = ResolverClient(), timeToLive: TimeInterval = 5 * 60) {
        self.fetcher = fetcher
        self.timeToLive = timeToLive
    }

    func currentRoster() async -> FederationRoster? {
        if let cached, Date().timeIntervalSince(cached.fetchedAt) < timeToLive {
            return cached.roster
        }
        guard let fetcher else {
            return nil
        }
        guard let roster = try? await fetcher.fetchRoster() else {
            // A failed refresh serves the stale roster.
            return cached?.roster
        }
        cached = (roster, Date())
        return roster
    }
}
