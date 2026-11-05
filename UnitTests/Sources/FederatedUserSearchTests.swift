//
// Copyright 2025 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

final class FederatedUserSearchTests {
    // MARK: - Bare handle detection
    
    @Test
    func bareHandleAcceptsPlainUsername() {
        #expect(FederatedUserSearch.bareHandle(from: "ana-souza") == "ana-souza")
    }
    
    @Test
    func bareHandleStripsSigilAndLowercases() {
        #expect(FederatedUserSearch.bareHandle(from: "@Ana-Souza") == "ana-souza")
    }
    
    @Test
    func bareHandleTrimsWhitespace() {
        #expect(FederatedUserSearch.bareHandle(from: "  ana.souza_2\n") == "ana.souza_2")
    }
    
    @Test
    func bareHandleAcceptsFullLocalpartCharset() {
        #expect(FederatedUserSearch.bareHandle(from: "a-b.c_d=e/f0") == "a-b.c_d=e/f0")
    }
    
    @Test
    func bareHandleRejectsShortQueries() {
        #expect(FederatedUserSearch.bareHandle(from: "ab") == nil)
        #expect(FederatedUserSearch.bareHandle(from: "@ab") == nil)
        #expect(FederatedUserSearch.bareHandle(from: "") == nil)
    }
    
    @Test
    func bareHandleRejectsFullAddresses() {
        #expect(FederatedUserSearch.bareHandle(from: "@ana-souza:gua.example") == nil)
        #expect(FederatedUserSearch.bareHandle(from: "ana-souza:gua.example") == nil)
        #expect(FederatedUserSearch.bareHandle(from: "@ana-souza:") == nil)
    }
    
    @Test
    func bareHandleRejectsInvalidCharacters() {
        #expect(FederatedUserSearch.bareHandle(from: "ana souza") == nil)
        #expect(FederatedUserSearch.bareHandle(from: "ana!") == nil)
        #expect(FederatedUserSearch.bareHandle(from: "an@a") == nil)
        #expect(FederatedUserSearch.bareHandle(from: "año-souza") == nil)
    }
    
    // MARK: - Roster parsing
    
    @Test
    func rosterDecodingIgnoresUnknownFieldsAndKeepsPolicy() throws {
        let roster = try JSONDecoder().decode(FederationRoster.self, from: Data(rosterJSON.utf8))
        
        #expect(roster.entries.count == 3)
        
        let first = roster.entries[0].homeserver
        #expect(first.serverName == "br.gua.example")
        #expect(first.searchVisibility == nil)
        #expect(first.searchGroups == nil)
        #expect(roster.entries[0].isActive)
        
        let second = roster.entries[1].homeserver
        #expect(second.serverName == "edu.gua.example")
        #expect(second.searchVisibility == "GROUP")
        #expect(second.searchGroups == ["edu"])
        
        #expect(!roster.entries[2].isActive)
    }
    
    // MARK: - Search visibility
    
    @Test
    func absentVisibilityIsGlobal() {
        #expect(RosterSearchVisibility(rawValue: nil) == .global)
    }
    
    @Test
    func knownVisibilityValues() {
        #expect(RosterSearchVisibility(rawValue: "global") == .global)
        #expect(RosterSearchVisibility(rawValue: "group") == .group)
        #expect(RosterSearchVisibility(rawValue: "server") == .server)
    }
    
    @Test
    func visibilityMatchingIsCaseInsensitive() {
        // The resolver serializes the policy uppercase, like the entry status.
        #expect(RosterSearchVisibility(rawValue: "GLOBAL") == .global)
        #expect(RosterSearchVisibility(rawValue: "GROUP") == .group)
        #expect(RosterSearchVisibility(rawValue: "SERVER") == .server)
    }
    
    @Test
    func unrecognizedVisibilityIsPreserved() {
        #expect(RosterSearchVisibility(rawValue: "invite") == .unrecognized("invite"))
    }
    
    // MARK: - Candidate construction
    
    @Test
    func candidatesLeadWithOwnServerThenFollowRosterOrder() {
        let roster = makeRoster([
            .init(serverName: "br.gua.example", searchVisibility: nil, searchGroups: nil),
            .init(serverName: "ca.gua.example", searchVisibility: "global", searchGroups: nil)
        ])
        
        let candidates = FederatedUserSearch.candidates(forHandle: "ana-souza", roster: roster, ownServerName: "br.gua.example")
        
        #expect(candidates == ["@ana-souza:br.gua.example", "@ana-souza:ca.gua.example"])
    }
    
    @Test
    func candidatesSkipInactiveEntries() {
        let roster = FederationRoster(entries: [
            .init(homeserver: .init(serverName: "ca.gua.example", searchVisibility: nil, searchGroups: nil), status: "ACTIVE"),
            .init(homeserver: .init(serverName: "old.gua.example", searchVisibility: nil, searchGroups: nil), status: "RETIRED"),
            .init(homeserver: .init(serverName: "new.gua.example", searchVisibility: nil, searchGroups: nil), status: "PENDING")
        ])
        
        let candidates = FederatedUserSearch.candidates(forHandle: "ana-souza", roster: roster, ownServerName: "br.gua.example")
        
        #expect(candidates == ["@ana-souza:br.gua.example", "@ana-souza:ca.gua.example"])
    }
    
    @Test
    func candidatesSkipServerVisibility() {
        let roster = makeRoster([
            .init(serverName: "ca.gua.example", searchVisibility: "GLOBAL", searchGroups: []),
            .init(serverName: "private.gua.example", searchVisibility: "SERVER", searchGroups: nil)
        ])
        
        let candidates = FederatedUserSearch.candidates(forHandle: "ana-souza", roster: roster, ownServerName: "br.gua.example")
        
        #expect(candidates == ["@ana-souza:br.gua.example", "@ana-souza:ca.gua.example"])
    }
    
    @Test
    func candidatesSkipUnrecognizedVisibility() {
        let roster = makeRoster([
            .init(serverName: "beta.gua.example", searchVisibility: "invite", searchGroups: nil)
        ])
        
        let candidates = FederatedUserSearch.candidates(forHandle: "ana-souza", roster: roster, ownServerName: "br.gua.example")
        
        #expect(candidates == ["@ana-souza:br.gua.example"])
    }
    
    @Test
    func groupVisibilityRequiresASharedGroup() {
        let roster = makeRoster([
            .init(serverName: "br.gua.example", searchVisibility: nil, searchGroups: ["edu", "partners"]),
            .init(serverName: "edu.gua.example", searchVisibility: "group", searchGroups: ["edu"]),
            .init(serverName: "gov.gua.example", searchVisibility: "group", searchGroups: ["gov"]),
            .init(serverName: "closed.gua.example", searchVisibility: "group", searchGroups: nil)
        ])
        
        let candidates = FederatedUserSearch.candidates(forHandle: "ana-souza", roster: roster, ownServerName: "br.gua.example")
        
        #expect(candidates == ["@ana-souza:br.gua.example", "@ana-souza:edu.gua.example"])
    }
    
    @Test
    func groupVisibilityExcludesSearcherWithoutGroups() {
        let roster = makeRoster([
            .init(serverName: "br.gua.example", searchVisibility: nil, searchGroups: nil),
            .init(serverName: "edu.gua.example", searchVisibility: "group", searchGroups: ["edu"])
        ])
        
        let candidates = FederatedUserSearch.candidates(forHandle: "ana-souza", roster: roster, ownServerName: "br.gua.example")
        
        #expect(candidates == ["@ana-souza:br.gua.example"])
    }
    
    @Test
    func groupVisibilityExcludesSearcherAbsentFromRoster() {
        let roster = makeRoster([
            .init(serverName: "ca.gua.example", searchVisibility: nil, searchGroups: nil),
            .init(serverName: "edu.gua.example", searchVisibility: "group", searchGroups: ["edu"])
        ])
        
        let candidates = FederatedUserSearch.candidates(forHandle: "ana-souza", roster: roster, ownServerName: "nowhere.example")
        
        #expect(candidates == ["@ana-souza:nowhere.example", "@ana-souza:ca.gua.example"])
    }
    
    // MARK: - Roster cache
    
    @Test
    func rosterIsCachedWithinTimeToLive() async {
        let fetcher = RosterFetcherStub(results: [.success(rosterA), .success(rosterB)])
        let cache = FederationRosterCache(fetcher: fetcher, timeToLive: 300)
        
        let first = await cache.currentRoster()
        let second = await cache.currentRoster()
        
        #expect(first == rosterA)
        #expect(second == rosterA)
        let fetchCount = await fetcher.fetchCount
        #expect(fetchCount == 1)
    }
    
    @Test
    func rosterRefreshesAfterExpiry() async {
        let fetcher = RosterFetcherStub(results: [.success(rosterA), .success(rosterB)])
        let cache = FederationRosterCache(fetcher: fetcher, timeToLive: 0)
        
        let first = await cache.currentRoster()
        let second = await cache.currentRoster()
        
        #expect(first == rosterA)
        #expect(second == rosterB)
        let fetchCount = await fetcher.fetchCount
        #expect(fetchCount == 2)
    }
    
    @Test
    func staleRosterIsServedWhenRefreshFails() async {
        let fetcher = RosterFetcherStub(results: [.success(rosterA), .failure(.malformedResponse)])
        let cache = FederationRosterCache(fetcher: fetcher, timeToLive: 0)
        
        let first = await cache.currentRoster()
        let second = await cache.currentRoster()
        
        #expect(first == rosterA)
        #expect(second == rosterA)
    }
    
    @Test
    func missingFetcherReturnsNoRoster() async {
        let cache = FederationRosterCache(fetcher: nil, timeToLive: 300)
        
        let roster = await cache.currentRoster()
        
        #expect(roster == nil)
    }
    
    // MARK: - Private
    
    private func makeRoster(_ servers: [FederationRosterServer]) -> FederationRoster {
        FederationRoster(entries: servers.map { FederationRosterEntry(homeserver: $0, status: "ACTIVE") })
    }
    
    private var rosterA: FederationRoster {
        makeRoster([.init(serverName: "a.gua.example", searchVisibility: nil, searchGroups: nil)])
    }
    
    private var rosterB: FederationRoster {
        makeRoster([.init(serverName: "b.gua.example", searchVisibility: nil, searchGroups: nil)])
    }
    
    /// A realistic resolver payload: the client only decodes what it needs and ignores the rest.
    private let rosterJSON = """
    {
      "version": 12,
      "generatedAt": "2025-08-14T12:00:00Z",
      "entries": [
        {
          "homeserver": {
            "id": "hs-br",
            "serverName": "br.gua.example",
            "baseUrl": "https://matrix.br.gua.example",
            "masIssuer": "https://auth.br.gua.example",
            "region": "br",
            "weight": 100,
            "acceptsNew": true,
            "signingKey": "ed25519:aaaa"
          },
          "status": "ACTIVE"
        },
        {
          "homeserver": {
            "id": "hs-edu",
            "serverName": "edu.gua.example",
            "baseUrl": "https://matrix.edu.gua.example",
            "masIssuer": "https://auth.edu.gua.example",
            "region": "ca",
            "weight": 10,
            "acceptsNew": false,
            "signingKey": "ed25519:bbbb",
            "searchVisibility": "GROUP",
            "searchGroups": ["edu"]
          },
          "status": "ACTIVE"
        },
        {
          "homeserver": {
            "id": "hs-old",
            "serverName": "old.gua.example",
            "baseUrl": "https://matrix.old.gua.example",
            "signingKey": "ed25519:cccc",
            "searchVisibility": "GLOBAL"
          },
          "status": "RETIRED"
        }
      ]
    }
    """
}

private actor RosterFetcherStub: FederationRosterFetching {
    private var results: [Result<FederationRoster, ResolverError>]
    private(set) var fetchCount = 0
    
    init(results: [Result<FederationRoster, ResolverError>]) {
        self.results = results
    }
    
    func fetchRoster() async throws -> FederationRoster {
        fetchCount += 1
        guard !results.isEmpty else { throw ResolverError.malformedResponse }
        return try results.removeFirst().get()
    }
}
