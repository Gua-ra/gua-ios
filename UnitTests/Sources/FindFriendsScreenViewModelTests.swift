//
// Copyright Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Contacts
@testable import ElementX
import XCTest

@MainActor
final class FindFriendsScreenViewModelTests: XCTestCase {
    private var clientProxy: ClientProxyMock!
    private var discovery: ContactDiscoveryServiceStub!
    private var viewModel: FindFriendsScreenViewModel!

    private static let unauthorized = ContactDiscoveryError.lookupFailed(IdentityServiceError.server(status: 401, message: nil))
    private static let friend = DiscoveredContact(localName: "Ana", phoneNumber: "+5511987654321", userId: "@ana:gua.test", username: "ana")

    override func setUp() {
        clientProxy = ClientProxyMock(.init(userID: "@me:gua.test"))
        clientProxy.accessToken = "token-at-open"
        clientProxy.fetchMediaPreviewConfigurationClosure = { [weak clientProxy] in
            clientProxy?.accessToken = "refreshed-token"
            return .success(nil)
        }
        discovery = ContactDiscoveryServiceStub()
    }

    func testTryAgainUsesTheTokenTheSessionHoldsNow() async throws {
        discovery.answer = { _ in throw ContactDiscoveryError.lookupFailed(IdentityServiceError.server(status: 500, message: nil)) }
        try await whenTheScreenOpens(reaching: .error)

        clientProxy.accessToken = "token-at-retry"
        discovery.answer = { _ in [Self.friend] }
        let deferred = deferFulfillment(viewModel.context.observe(\.viewState.phase)) { $0 == .loaded }
        viewModel.context.send(viewAction: .retry)
        try await deferred.fulfill()

        XCTAssertEqual(discovery.receivedAccessTokens, ["token-at-open", "token-at-retry"])
    }

    func testAnExpiredTokenIsRefreshedAndTheLookupRetriedOnce() async throws {
        discovery.answer = { accessToken in
            guard accessToken == "refreshed-token" else { throw Self.unauthorized }
            return [Self.friend]
        }

        try await whenTheScreenOpens(reaching: .loaded)

        XCTAssertEqual(discovery.receivedAccessTokens, ["token-at-open", "refreshed-token"])
        XCTAssertEqual(clientProxy.fetchMediaPreviewConfigurationCallsCount, 1)
        XCTAssertEqual(viewModel.context.viewState.contacts, [Self.friend])
    }

    func testARefusalAfterTheRefreshIsNotRetriedAgain() async throws {
        discovery.answer = { _ in throw Self.unauthorized }

        try await whenTheScreenOpens(reaching: .error)

        XCTAssertEqual(discovery.receivedAccessTokens.count, 2)
        XCTAssertEqual(clientProxy.fetchMediaPreviewConfigurationCallsCount, 1)
    }

    func testOtherFailuresAreNotRetried() async throws {
        discovery.answer = { _ in throw ContactDiscoveryError.lookupFailed(IdentityServiceError.rateLimited) }

        try await whenTheScreenOpens(reaching: .error)

        XCTAssertEqual(discovery.receivedAccessTokens.count, 1)
        XCTAssertEqual(clientProxy.fetchMediaPreviewConfigurationCallsCount, 0)
    }

    // MARK: - Helpers

    private func whenTheScreenOpens(reaching phase: FindFriendsScreenPhase) async throws {
        viewModel = FindFriendsScreenViewModel(contactDiscoveryService: discovery, clientProxy: clientProxy)
        let deferred = deferFulfillment(viewModel.context.observe(\.viewState.phase)) { $0 == phase }
        try await deferred.fulfill()
    }
}

@MainActor
private final class ContactDiscoveryServiceStub: ContactDiscoveryServiceProtocol {
    var answer: (String) async throws -> [DiscoveredContact] = { _ in [] }
    private(set) var receivedAccessTokens: [String] = []

    var authorizationStatus: CNAuthorizationStatus {
        .authorized
    }

    func requestAccess() async -> Bool {
        true
    }

    func discover(accessToken: String) async throws -> [DiscoveredContact] {
        receivedAccessTokens.append(accessToken)
        return try await answer(accessToken)
    }
}
