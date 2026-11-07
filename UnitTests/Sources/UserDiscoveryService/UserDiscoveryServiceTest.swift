//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Testing

@MainActor
struct UserDiscoveryServiceTest {
    private var service: UserDiscoveryService
    private var clientProxy: ClientProxyMock
    
    private var searchResults: [UserProfile] {
        [.mockAlice, .mockBob, .mockCharlie]
    }
    
    init() {
        clientProxy = .init(.init(userID: "@foo:matrix.org"))
        // A bare handle now always resolves against the searcher's own server, so the default
        // has to be "no such user" or every search in this file would invent one. Tests that
        // want a hit override this with their own returnValue or closure.
        clientProxy.profileForReturnValue = .failure(.sdkError(ClientProxyMockError.generic))
        service = UserDiscoveryService(clientProxy: clientProxy, federationRosterProvider: nil)
    }
    
    @Test
    func queryShowingResults() async {
        clientProxy.searchUsersSearchTermLimitReturnValue = .success(.init(results: [UserProfile.mockAlice], limited: true))
        
        let results = await (try? search(query: "AAA").get()) ?? []
        assertSearchResults(results, toBe: 1)
    }
    
    @Test
    func ownerIsFiltered() async {
        clientProxy.searchUsersSearchTermLimitReturnValue = .success(.init(results: [UserProfile(userID: "@foo:matrix.org")], limited: true))
        
        let results = await (try? search(query: "AAA").get()) ?? []
        assertSearchResults(results, toBe: 0)
    }
    
    @Test
    func getProfileIsNotCalledForATooShortQuery() async {
        clientProxy.searchUsersSearchTermLimitReturnValue = .success(.init(results: searchResults, limited: true))
        clientProxy.profileForReturnValue = .success(.init(userID: "@alice:matrix.org"))
        
        // Below the three-character floor, so this is not a handle and must not fan out.
        let results = await (try? search(query: "AA").get()) ?? []
        assertSearchResults(results, toBe: 3)
        #expect(!clientProxy.profileForCalled)
    }
    
    @Test
    func getProfileIsNotCalledForAccountOwnerID() async {
        clientProxy.searchUsersSearchTermLimitReturnValue = .success(.init(results: searchResults, limited: true))
        clientProxy.profileForReturnValue = .success(.init(userID: "@alice:matrix.org"))
        
        let results = await (try? search(query: "foo:matrix.org").get()) ?? []
        assertSearchResults(results, toBe: 3)
        #expect(!clientProxy.profileForCalled)
    }
    
    @Test
    func localResultShows() async {
        clientProxy.searchUsersSearchTermLimitReturnValue = .success(.init(results: searchResults, limited: true))
        clientProxy.profileForReturnValue = .success(.init(userID: "@some:matrix.org"))
        
        let results = await (try? search(query: "@a:b.com").get()) ?? []
        
        assertSearchResults(results, toBe: 4)
        #expect(clientProxy.profileForCalled)
    }
    
    @Test
    func localResultShowsOnSearchError() async {
        clientProxy.searchUsersSearchTermLimitReturnValue = .failure(.sdkError(ClientProxyMockError.generic))
        clientProxy.profileForReturnValue = .success(.init(userID: "@some:matrix.org"))
        
        let results = await (try? search(query: "@a:b.com").get()) ?? []
        
        assertSearchResults(results, toBe: 1)
        #expect(clientProxy.profileForCalled)
    }
    
    @Test
    func searchErrorTriggers() async {
        clientProxy.searchUsersSearchTermLimitReturnValue = .failure(.sdkError(ClientProxyMockError.generic))
        clientProxy.profileForReturnValue = .success(.init(userID: "@some:matrix.org"))
        
        switch await search(query: "some query") {
        case .success:
            Issue.record("Search users must fail")
        case .failure(let error):
            #expect(error == UserDiscoveryErrorType.failedSearchingUsers)
        }
        
        #expect(!clientProxy.profileForCalled)
    }
    
    @Test
    func localResultWithDuplicates() async {
        clientProxy.searchUsersSearchTermLimitReturnValue = .success(.init(results: searchResults, limited: true))
        clientProxy.profileForReturnValue = .success(.init(userID: "@bob:matrix.org"))
        
        let results = await (try? search(query: "@a:b.com").get()) ?? []
        
        assertSearchResults(results, toBe: 3)
        let firstUserID = results.first?.id
        #expect(firstUserID == "@bob:matrix.org")
        #expect(clientProxy.profileForCalled)
    }
    
    @Test
    func searchResultsShowWhenGetProfileFails() async {
        clientProxy.searchUsersSearchTermLimitReturnValue = .success(.init(results: searchResults, limited: true))
        clientProxy.profileForReturnValue = .failure(.sdkError(ClientProxyMockError.generic))
        
        let results = await (try? search(query: "@a:b.com").get()) ?? []
        
        let firstUserID = results.first?.id
        #expect(firstUserID == "@a:b.com")
        #expect(clientProxy.profileForCalled)
    }
    
    // MARK: - Gua federated bare-handle search
    
    @Test
    mutating func bareHandleFansOutAcrossFederationIncludingOwnServer() async {
        makeFederatedService(entries: [("matrix.org", "ACTIVE"), ("ca.gua.example", "ACTIVE"), ("br.gua.example", "ACTIVE")])
        clientProxy.searchUsersSearchTermLimitReturnValue = .success(.init(results: [.mockAlice], limited: false))
        clientProxy.profileForClosure = { userID in .success(.init(userID: userID)) }
        
        let results = await (try? search(query: "ana-souza").get()) ?? []
        
        #expect(results.map(\.id) == ["@alice:matrix.org",
                                      "@ana-souza:matrix.org",
                                      "@ana-souza:ca.gua.example",
                                      "@ana-souza:br.gua.example"])
    }
    
    @Test
    mutating func federatedLookupFailuresAreDropped() async {
        makeFederatedService(entries: [("matrix.org", "ACTIVE"), ("ca.gua.example", "ACTIVE"), ("br.gua.example", "ACTIVE")])
        clientProxy.searchUsersSearchTermLimitReturnValue = .success(.init(results: [.mockAlice], limited: false))
        clientProxy.profileForClosure = { userID in
            userID == "@ana-souza:br.gua.example" ? .success(.init(userID: userID, displayName: "Ana")) : .failure(.sdkError(ClientProxyMockError.generic))
        }
        
        let results = await (try? search(query: "ana-souza").get()) ?? []
        
        #expect(results.map(\.id) == ["@alice:matrix.org", "@ana-souza:br.gua.example"])
    }
    
    @Test
    mutating func federatedMatchesAreDeduplicatedAgainstLocalResults() async {
        makeFederatedService(entries: [("matrix.org", "ACTIVE"), ("ca.gua.example", "ACTIVE")])
        clientProxy.searchUsersSearchTermLimitReturnValue = .success(.init(results: [.init(userID: "@ana-souza:ca.gua.example")], limited: false))
        clientProxy.profileForClosure = { userID in .success(.init(userID: userID)) }
        
        let results = await (try? search(query: "ana-souza").get()) ?? []
        
        #expect(results.map(\.id) == ["@ana-souza:ca.gua.example", "@ana-souza:matrix.org"])
    }
    
    @Test
    mutating func federatedMatchesShowWhenLocalSearchFails() async {
        makeFederatedService(entries: [("matrix.org", "ACTIVE"), ("ca.gua.example", "ACTIVE")])
        clientProxy.searchUsersSearchTermLimitReturnValue = .failure(.sdkError(ClientProxyMockError.generic))
        clientProxy.profileForClosure = { userID in .success(.init(userID: userID)) }
        
        let results = await (try? search(query: "ana-souza").get()) ?? []
        
        #expect(results.map(\.id) == ["@ana-souza:matrix.org", "@ana-souza:ca.gua.example"])
    }
    
    @Test
    mutating func slowFederatedLookupIsDroppedAfterTimeout() async {
        makeFederatedService(entries: [("matrix.org", "ACTIVE"), ("ca.gua.example", "ACTIVE"), ("br.gua.example", "ACTIVE")],
                             lookupTimeout: .milliseconds(50))
        clientProxy.searchUsersSearchTermLimitReturnValue = .success(.init(results: [.mockAlice], limited: false))
        clientProxy.profileForClosure = { userID in
            if userID == "@ana-souza:ca.gua.example" {
                try? await Task.sleep(for: .seconds(10))
            }
            return .success(.init(userID: userID))
        }
        
        let results = await (try? search(query: "ana-souza").get()) ?? []
        
        #expect(results.map(\.id) == ["@alice:matrix.org",
                                      "@ana-souza:matrix.org",
                                      "@ana-souza:br.gua.example"])
    }
    
    /// Regression: an unconfigured or unreachable resolver must not remove the ability to find
    /// someone on your own server. That is the common case and the whole point of the fix.
    @Test
    mutating func ownServerIsStillSearchedWithoutARoster() async {
        service = UserDiscoveryService(clientProxy: clientProxy, federationRosterProvider: nil)
        clientProxy.searchUsersSearchTermLimitReturnValue = .success(.init(results: [], limited: false))
        clientProxy.profileForClosure = { userID in .success(.init(userID: userID)) }
        
        let results = await (try? search(query: "ana-souza").get()) ?? []
        
        #expect(results.map(\.id) == ["@ana-souza:matrix.org"])
    }
    
    @Test
    mutating func ownServerIsStillSearchedWhenTheRosterIsEmpty() async {
        makeFederatedService(entries: [])
        clientProxy.searchUsersSearchTermLimitReturnValue = .success(.init(results: [], limited: false))
        clientProxy.profileForClosure = { userID in .success(.init(userID: userID)) }
        
        let results = await (try? search(query: "ana-souza").get()) ?? []
        
        #expect(results.map(\.id) == ["@ana-souza:matrix.org"])
    }
    
    @Test
    mutating func nonHandleQueryDoesNotFanOut() async {
        makeFederatedService(entries: [("matrix.org", "ACTIVE"), ("ca.gua.example", "ACTIVE")])
        clientProxy.searchUsersSearchTermLimitReturnValue = .success(.init(results: [.mockAlice], limited: false))
        
        let results = await (try? search(query: "ana souza").get()) ?? []
        
        assertSearchResults(results, toBe: 1)
        #expect(!clientProxy.profileForCalled)
    }
    
    // MARK: - Private
    
    private mutating func makeFederatedService(entries: [(serverName: String, status: String)], lookupTimeout: Duration = .seconds(3)) {
        let roster = FederationRoster(entries: entries.map { entry in
            FederationRosterEntry(homeserver: .init(serverName: entry.serverName, searchVisibility: nil, searchGroups: nil),
                                  status: entry.status)
        })
        service = UserDiscoveryService(clientProxy: clientProxy,
                                       federationRosterProvider: StaticRosterProvider(roster: roster),
                                       federatedLookupTimeout: lookupTimeout)
    }
    
    private func assertSearchResults(_ results: [UserProfile], toBe count: Int) {
        #expect(count >= 0)
        #expect(results.count == count)
        #expect(results.isEmpty == (count == 0))
    }
    
    private func search(query: String) async -> Result<[UserProfile], UserDiscoveryErrorType> {
        await service.searchProfiles(with: query)
    }
}

private struct StaticRosterProvider: FederationRosterProviding {
    let roster: FederationRoster?
    
    func currentRoster() async -> FederationRoster? {
        roster
    }
}
