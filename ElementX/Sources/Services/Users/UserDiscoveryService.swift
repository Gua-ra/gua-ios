//
// Copyright 2023, 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

final class UserDiscoveryService: UserDiscoveryServiceProtocol {
    private let clientProxy: ClientProxyProtocol
    private let federationRosterProvider: FederationRosterProviding?
    private let federatedLookupTimeout: Duration

    init(clientProxy: ClientProxyProtocol,
         federationRosterProvider: FederationRosterProviding? = FederationRosterCache.shared,
         federatedLookupTimeout: Duration = .seconds(3)) {
        self.clientProxy = clientProxy
        self.federationRosterProvider = federationRosterProvider
        self.federatedLookupTimeout = federatedLookupTimeout
    }

    func searchProfiles(with searchQuery: String) async -> Result<[UserProfileProxy], UserDiscoveryErrorType> {
        async let queriedProfile = profileIfPossible(with: searchQuery)
        async let federatedProfiles = federatedProfiles(matching: searchQuery)

        do {
            async let searchedUsers = clientProxy.searchUsers(searchTerm: searchQuery, limit: 10).get()
            let users = try await merge(queriedProfile: queriedProfile, searchResults: searchedUsers)
            let merged = await appendFederated(federatedProfiles, to: users)
            return .success(filterAccountOwner(merged))
        } catch {
            // we want to show the profile (if any) and federated matches even if the search fails
            let fallback = await appendFederated(federatedProfiles, to: queriedProfile.map { [$0] } ?? [])
            guard !fallback.isEmpty else {
                return .failure(.failedSearchingUsers)
            }
            return .success(filterAccountOwner(fallback))
        }
    }

    private func merge(queriedProfile: UserProfileProxy?, searchResults: SearchUsersResultsProxy) -> [UserProfileProxy] {
        let searchResults = searchResults.results
        
        guard let queriedProfile else {
            return searchResults
        }

        let filteredSearchResult = searchResults.filter {
            $0.userID != queriedProfile.userID
        }

        return [queriedProfile] + filteredSearchResult
    }
    
    private func profileIfPossible(with searchQuery: String) async -> UserProfileProxy? {
        guard searchQuery.isMatrixIdentifier, searchQuery != clientProxy.userID else {
            return nil
        }
        
        let getProfileResult = try? await clientProxy.profile(for: searchQuery).get()
        
        // fallback to a "local profile" if the profile api fails
        return getProfileResult ?? .init(userID: searchQuery)
    }

    private func filterAccountOwner(_ profiles: [UserProfileProxy]) -> [UserProfileProxy] {
        let accountOwnerID = clientProxy.userID
        return profiles.filter { $0.userID != accountOwnerID }
    }

    // MARK: - Gua federated bare-handle search

    /// GUA FORK: exact-handle matches for a bare username, on the searcher's own homeserver and on
    /// the other homeservers of the federation, honouring each server's discoverability policy. Empty
    /// when the query is not a bare handle.
    ///
    /// The own-server lookup must not depend on the roster, which only adds the other servers.
    private func federatedProfiles(matching searchQuery: String) async -> [UserProfileProxy] {
        guard let handle = FederatedUserSearch.bareHandle(from: searchQuery) else {
            return []
        }

        var candidates = ["@\(handle):\(ownServerName)"]

        if let federationRosterProvider,
           let roster = await federationRosterProvider.currentRoster() {
            candidates += FederatedUserSearch.candidates(forHandle: handle,
                                                         roster: roster,
                                                         ownServerName: ownServerName)
                .filter { $0 != candidates[0] }
        }

        guard !candidates.isEmpty else {
            return []
        }

        return await withTaskGroup(of: (Int, UserProfileProxy?).self) { group in
            for (index, userID) in candidates.enumerated() {
                group.addTask {
                    await (index, self.federatedProfile(for: userID))
                }
            }

            var profiles = [(index: Int, profile: UserProfileProxy)]()
            for await (index, profile) in group {
                if let profile {
                    profiles.append((index, profile))
                }
            }
            return profiles.sorted { $0.index < $1.index }.map(\.profile)
        }
    }

    /// Resolves one candidate through the same profile lookup used for a full `@user:server` address.
    /// Failed or slow lookups are dropped, so one server cannot stall the search.
    private func federatedProfile(for userID: String) async -> UserProfileProxy? {
        await withTaskGroup(of: UserProfileProxy?.self) { group in
            group.addTask {
                try? await self.clientProxy.profile(for: userID).get()
            }
            group.addTask {
                try? await Task.sleep(for: self.federatedLookupTimeout)
                return nil
            }

            let profile = await group.next() ?? nil
            group.cancelAll()
            return profile
        }
    }

    /// Local results first, then the federated exact matches that are not already present.
    private func appendFederated(_ federatedProfiles: [UserProfileProxy], to users: [UserProfileProxy]) -> [UserProfileProxy] {
        guard !federatedProfiles.isEmpty else {
            return users
        }
        let knownUserIDs = Set(users.map(\.userID))
        return users + federatedProfiles.filter { !knownUserIDs.contains($0.userID) }
    }

    private var ownServerName: String {
        let userID = clientProxy.userID
        guard let colonIndex = userID.firstIndex(of: ":") else {
            return ""
        }
        return String(userID[userID.index(after: colonIndex)...])
    }
}

private extension String {
    var isMatrixIdentifier: Bool {
        MatrixEntityRegex.isMatrixUserIdentifier(self)
    }
}
