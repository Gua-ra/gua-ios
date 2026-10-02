//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// How a federation homeserver lets its users be found by bare-handle search from other servers.
/// Absent means `global`. Unrecognized values are not discoverable, so an older client never widens
/// a stricter policy.
enum RosterSearchVisibility: Equatable {
    /// Discoverable from every federation server.
    case global
    /// Discoverable only from servers sharing at least one search group.
    case group
    /// Discoverable only from the user's own server, so never through federated search.
    case server
    case unrecognized(String)

    init(rawValue: String?) {
        // The resolver serializes the policy uppercase (`GLOBAL`); match case-insensitively.
        switch rawValue?.lowercased() {
        case nil, "global": self = .global
        case "group": self = .group
        case "server": self = .server
        case let .some(other): self = .unrecognized(other)
        }
    }
}

/// Federated bare-username search: for a handle typed with no homeserver (`ana-souza`), the client
/// fans out an exact-match lookup to the federation servers in the resolver roster, honouring each
/// server's discoverability policy.
enum FederatedUserSearch {
    /// Normalizes a search query into a bare handle, or `nil` when it is not one: an optional leading
    /// `@`, at least 3 localpart characters, and no `:` (the user is typing a full address).
    static func bareHandle(from query: String) -> String? {
        var handle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !handle.contains(":") else { return nil }
        if handle.hasPrefix("@") {
            handle = String(handle.dropFirst())
        }
        guard handle.range(of: "^[a-z0-9._=/-]{3,}$", options: .regularExpression) != nil else { return nil }
        return handle
    }

    /// The full user IDs to look up for a bare handle: the searcher's own server first, then one per
    /// ACTIVE roster server that allows discovery from it, in roster order. The own server is included
    /// because Synapse's directory search only returns users who already share a room.
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

/// Provides the current federation roster, or `nil` when it is not available. Unavailability is
/// not an error: search degrades to local-only.
protocol FederationRosterProviding: Sendable {
    func currentRoster() async -> FederationRoster?
}

/// In-memory roster cache with a short TTL, so a burst of searches does not hammer the resolver.
/// Keeps serving the last good roster when a refresh fails.
actor FederationRosterCache: FederationRosterProviding {
    static let shared = FederationRosterCache()

    private let fetcher: FederationRosterFetching?
    private let timeToLive: TimeInterval
    private var cached: (roster: FederationRoster, fetchedAt: Date)?

    /// A `nil` fetcher (an unconfigured resolver) disables federated search.
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
