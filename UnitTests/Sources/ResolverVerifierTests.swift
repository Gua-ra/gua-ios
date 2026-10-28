//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import XCTest

/// The orchestrator over a stubbed resolver: every endpoint is canned from the golden vectors, so the checks run
/// against signatures that really verify, and the transport never leaves the process.
final class ResolverVerifierTests: XCTestCase {
    private static let baseURL = URL(string: "https://resolver.example")!
    private var vectors: [String: Any]!
    private var appSettings: AppSettings!
    private var checkpoints: InMemoryCheckpointStore!

    /// A moment inside every validity window the vectors sign.
    private let now = ResolverInstant(iso: "2026-10-27T00:00:00Z")!.epochMilliseconds

    override func setUpWithError() throws {
        VerifierStub.reset()
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "gua-client-verification-v1-vectors.json", withExtension: nil))
        vectors = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        appSettings = AppSettings()
        appSettings.guaResolverVerificationEnabled = true
        checkpoints = InMemoryCheckpointStore()
    }

    override func tearDown() {
        appSettings.guaResolverVerificationEnabled = true
        VerifierStub.reset()
    }

    // MARK: - Trust roots and transport

    func testDevelopmentTrustRootsParseOrStayEmpty() {
        let parsed = ResolverTrustRoots(developmentSecret: "gua-authority-dev:AAAA, other:BBBB")
        XCTAssertEqual(parsed.authorityKeys, [ResolverTrustedKey(id: "gua-authority-dev", publicKey: "AAAA"),
                                              ResolverTrustedKey(id: "other", publicKey: "BBBB")])
        XCTAssertEqual(parsed.policyKeys, parsed.authorityKeys)
        XCTAssertEqual(parsed.authorityThreshold, 1)
        XCTAssertEqual(parsed.policyThreshold, 1)
        XCTAssertEqual(ResolverTrustRoots(developmentSecret: nil), .empty)
        XCTAssertEqual(ResolverTrustRoots(developmentSecret: ""), .empty)
        XCTAssertEqual(ResolverTrustRoots(developmentSecret: "gua-authority-dev"), .empty)
        XCTAssertFalse(ResolverTrustRoots.empty.hasAuthorityKeys)
        XCTAssertTrue(ResolverTrustRoots.production.hasAuthorityKeys)
    }

    func testNoTrustRootsIsUnverifiableAndFetchesNothing() async throws {
        let report = try await XCTUnwrap(makeVerifier(trustRoots: .empty).verify(resolution: answer(.br), phoneNumber: "+5511987654321"))

        XCTAssertEqual(report.rosterSignature, .unverifiable(reason: "no_trust_roots"))
        XCTAssertEqual(report.policy, .unverifiable(reason: "no_trust_roots"))
        XCTAssertEqual(report.placement, .unverifiable(reason: "no_trust_roots"))
        XCTAssertEqual(report.overall, .unverifiable(.rosterSignature))
        XCTAssertTrue(VerifierStub.requestedPaths.isEmpty)
    }

    func testKillSwitchOffVerifiesNothing() async {
        appSettings.guaResolverVerificationEnabled = false
        let verifier = makeVerifier(trustRoots: trustRoots(ofRoster: 0))

        let report = await verifier.verify(resolution: answer(.br), phoneNumber: "+5511987654321")

        XCTAssertNil(report)
        XCTAssertNil(verifier.lastReport)
        XCTAssertTrue(VerifierStub.requestedPaths.isEmpty)
    }

    func testRosterUnavailableIsUnverifiable() async throws {
        VerifierStub.respond(path: "/roster", status: 503, body: "{}")
        let report = try await XCTUnwrap(makeVerifier(trustRoots: trustRoots(ofRoster: 0)).verify(resolution: answer(.br), phoneNumber: "+5511987654321"))

        XCTAssertEqual(report.rosterSignature, .unverifiable(reason: "roster_unavailable"))
        XCTAssertEqual(report.homeserverMatch, .unverifiable)
        XCTAssertEqual(report.overall, .unverifiable(.rosterSignature))
        XCTAssertEqual(VerifierStub.requestedPaths, ["/roster"])
    }

    func testTransportFailureIsUnverifiable() async throws {
        VerifierStub.failsTransport = true
        let report = try await XCTUnwrap(makeVerifier(trustRoots: trustRoots(ofRoster: 0)).verify(resolution: answer(.br), phoneNumber: "+5511987654321"))

        XCTAssertEqual(report.rosterSignature, .unverifiable(reason: "roster_unavailable"))
        XCTAssertEqual(report.overall, .unverifiable(.rosterSignature))
    }

    func testMixedRosterFormIsRefusedBeforeAnySignatureCheck() async throws {
        let mixed = try XCTUnwrap(rosterRejections.first { $0["clientOnly"] as? Bool == true })
        try VerifierStub.respond(path: "/roster", status: 200, body: json(mixed["roster"]))
        let report = try await XCTUnwrap(makeVerifier(trustRoots: trustRoots(ofRoster: 1)).verify(resolution: answer(.br), phoneNumber: "+5511987654321"))

        XCTAssertEqual(report.rosterForm, "mixed")
        XCTAssertEqual(report.rosterSignature, .unverifiable(reason: "mixed_roster_form"))
        XCTAssertEqual(report.overall, .unverifiable(.rosterSignature))
        XCTAssertEqual(VerifierStub.requestedPaths, ["/roster"])
    }

    func testTamperedRosterIsInvalidAndStopsTheDependentChecks() async throws {
        try VerifierStub.respond(path: "/roster", status: 200, body: json(rosterRejections[0]["roster"]))
        let report = try await XCTUnwrap(makeVerifier(trustRoots: trustRoots(of: rosterRejections[0])).verify(resolution: answer(.br), phoneNumber: "+5511987654321"))

        XCTAssertEqual(report.rosterSignature, .invalid(reason: "bad_signature"))
        XCTAssertEqual(report.logConsistency, .unverifiable(reason: "roster_unverified"))
        XCTAssertEqual(report.overall, .failed(.rosterSignature))
        XCTAssertNil(checkpoints.checkpoint(for: Self.baseURL))
    }

    // MARK: - Log consistency

    func testFirstCheckpointIsPinned() async throws {
        try serveRoster(0)
        VerifierStub.respond(path: "/policy/routing", status: 404, body: "{}")
        let report = try await XCTUnwrap(makeVerifier(trustRoots: trustRoots(ofRoster: 0)).verify(resolution: answer(.br), phoneNumber: "+5511987654321"))

        XCTAssertEqual(report.logConsistency, .firstSeen)
        XCTAssertEqual(checkpoints.checkpoint(for: Self.baseURL), RosterLogCheckpoint(merkleRoot: logRoot(size: 3), size: 3))
    }

    func testConsistencyProofMovesThePinForward() async throws {
        checkpoints.store(RosterLogCheckpoint(merkleRoot: logRoot(size: 3), size: 3), for: Self.baseURL)
        try serveRoster(1)
        try VerifierStub.respond(path: "/roster/log/consistency", status: 200,
                                 body: json(["first": 3, "second": 7, "proof": consistencyProof(first: 3, second: 7)]))
        VerifierStub.respond(path: "/policy/routing", status: 404, body: "{}")
        let report = try await XCTUnwrap(makeVerifier(trustRoots: trustRoots(ofRoster: 1)).verify(resolution: answer(.br), phoneNumber: "+5511987654321"))

        XCTAssertEqual(report.logConsistency, .consistent)
        XCTAssertEqual(checkpoints.checkpoint(for: Self.baseURL), RosterLogCheckpoint(merkleRoot: logRoot(size: 7), size: 7))
        XCTAssertEqual(VerifierStub.requestedQueries["/roster/log/consistency"], "first=3&second=7")
    }

    func testBrokenConsistencyProofIsInconsistentAndLeavesThePin() async throws {
        let pinned = RosterLogCheckpoint(merkleRoot: logRoot(size: 4), size: 3)
        checkpoints.store(pinned, for: Self.baseURL)
        try serveRoster(1)
        try VerifierStub.respond(path: "/roster/log/consistency", status: 200,
                                 body: json(["first": 3, "second": 7, "proof": consistencyProof(first: 3, second: 7)]))
        VerifierStub.respond(path: "/policy/routing", status: 404, body: "{}")
        let report = try await XCTUnwrap(makeVerifier(trustRoots: trustRoots(ofRoster: 1)).verify(resolution: answer(.br), phoneNumber: "+5511987654321"))

        XCTAssertEqual(report.logConsistency, .inconsistent)
        XCTAssertEqual(report.overall, .failed(.logConsistency))
        XCTAssertEqual(checkpoints.checkpoint(for: Self.baseURL), pinned)
    }

    func testMissingProofEndpointIsUnverifiableAndLeavesThePin() async throws {
        let pinned = RosterLogCheckpoint(merkleRoot: logRoot(size: 3), size: 3)
        checkpoints.store(pinned, for: Self.baseURL)
        try serveRoster(1)
        VerifierStub.respond(path: "/roster/log/consistency", status: 404, body: "{}")
        VerifierStub.respond(path: "/policy/routing", status: 404, body: "{}")
        let report = try await XCTUnwrap(makeVerifier(trustRoots: trustRoots(ofRoster: 1)).verify(resolution: answer(.br), phoneNumber: "+5511987654321"))

        XCTAssertEqual(report.logConsistency, .unverifiable(reason: "log_unavailable"))
        XCTAssertEqual(checkpoints.checkpoint(for: Self.baseURL), pinned)
    }

    func testSmallerServedTreeIsARollback() async throws {
        let pinned = RosterLogCheckpoint(merkleRoot: logRoot(size: 7), size: 7)
        checkpoints.store(pinned, for: Self.baseURL)
        try serveRoster(0)
        VerifierStub.respond(path: "/policy/routing", status: 404, body: "{}")
        let report = try await XCTUnwrap(makeVerifier(trustRoots: trustRoots(ofRoster: 0)).verify(resolution: answer(.br), phoneNumber: "+5511987654321"))

        XCTAssertEqual(report.logConsistency, .rollback)
        XCTAssertEqual(report.overall, .failed(.logConsistency))
        XCTAssertEqual(checkpoints.checkpoint(for: Self.baseURL), pinned)
        XCTAssertFalse(VerifierStub.requestedPaths.contains("/roster/log/consistency"))
    }

    // MARK: - Policy and placement

    func testNoPolicyServedIsNotPresentAndThePlacementReproduces() async throws {
        try serveRoster(0)
        VerifierStub.respond(path: "/policy/routing", status: 404, body: "{}")
        let report = try await XCTUnwrap(makeVerifier(trustRoots: trustRoots(ofRoster: 0)).verify(resolution: answer(.br), phoneNumber: "+5511987654321"))

        XCTAssertEqual(report.rosterVersion, 3)
        XCTAssertEqual(report.rosterForm, "v1")
        XCTAssertEqual(report.rosterSignature, .valid)
        XCTAssertEqual(report.homeserverMatch, .activeMatch)
        XCTAssertEqual(report.memberEntry, .valid)
        XCTAssertEqual(report.policy, .notPresent)
        XCTAssertEqual(report.placement, .match)
        XCTAssertEqual(report.overall, .verified)
        XCTAssertFalse(VerifierStub.requestedPaths.contains("/roster/log"))
    }

    func testPolicyPresentAndValidRoutesThePlacement() async throws {
        try serveRoster(1)
        try VerifierStub.respond(path: "/policy/routing", status: 200, body: json(policies[0]["bundle"]))
        try VerifierStub.respond(path: "/roster/log", status: 200, body: logDocument())
        let report = try await XCTUnwrap(makeVerifier(trustRoots: trustRoots(ofRoster: 1, policy: 0)).verify(resolution: answer(.br), phoneNumber: "+5511987654321"))

        XCTAssertEqual(report.rosterVersion, 7)
        XCTAssertEqual(report.rosterSignature, .valid)
        XCTAssertEqual(report.policy, .valid)
        XCTAssertEqual(report.placement, .match)
        XCTAssertEqual(report.overall, .verified)
        XCTAssertEqual(Set(VerifierStub.requestedPaths), ["/roster", "/policy/routing", "/roster/log"])
    }

    func testPolicySignedByAnUntrustedKeyIsInvalid() async throws {
        try serveRoster(1)
        try VerifierStub.respond(path: "/policy/routing", status: 200, body: json(policyRejections[0]["bundle"]))
        let report = try await XCTUnwrap(makeVerifier(trustRoots: trustRoots(ofRoster: 1, policy: 0)).verify(resolution: answer(.br), phoneNumber: "+5511987654321"))

        XCTAssertEqual(report.policy, .invalid(reason: "unknown_key_id"))
        XCTAssertEqual(report.placement, .unverifiable(reason: "policy_unverified"))
        XCTAssertEqual(report.overall, .failed(.policy))
    }

    func testPolicyWithoutPolicyKeysIsUnverifiable() async throws {
        try serveRoster(1)
        try VerifierStub.respond(path: "/policy/routing", status: 200, body: json(policies[0]["bundle"]))
        let report = try await XCTUnwrap(makeVerifier(trustRoots: trustRoots(ofRoster: 1)).verify(resolution: answer(.br), phoneNumber: "+5511987654321"))

        XCTAssertEqual(report.policy, .unverifiable(reason: "no_policy_keys"))
        XCTAssertEqual(report.overall, .unverifiable(.policy))
    }

    func testAnswerForAnUnjustifiedPlacementIsAMismatch() async throws {
        try serveRoster(1)
        VerifierStub.respond(path: "/policy/routing", status: 404, body: "{}")
        // Without the policy the fallback places +5511987654321 on hs-ca, so an answer naming hs-br is unjustified.
        let report = try await XCTUnwrap(makeVerifier(trustRoots: trustRoots(ofRoster: 1)).verify(resolution: answer(.br), phoneNumber: "+5511987654321"))

        XCTAssertEqual(report.placement, .mismatch)
        XCTAssertEqual(report.overall, .failed(.placement))
    }

    func testAnswerWithoutTheExistsFieldIsIndeterminate() async throws {
        try serveRoster(1)
        VerifierStub.respond(path: "/policy/routing", status: 404, body: "{}")
        var resolution = answer(.br)
        resolution.existsIsServed = false
        let report = try await XCTUnwrap(makeVerifier(trustRoots: trustRoots(ofRoster: 1)).verify(resolution: resolution, phoneNumber: "+5511987654321"))

        XCTAssertEqual(report.placement, .indeterminate)
        XCTAssertEqual(report.overall, .verified)
    }

    func testResolveAnswerWithoutTheExistsFieldSelectsTheServedHomeserver() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VerifierStubURLProtocol.self]
        let client = ResolverClient(baseURL: Self.baseURL, session: URLSession(configuration: configuration))
        let ref: [String: Any] = ["serverName": "br.gua.test", "baseUrl": "https://matrix.br.gua.test"]

        try VerifierStub.respond(path: "/resolve", status: 200, body: json(["registerAt": ref]))
        let registration = try await client.resolve(phoneNumber: "+5511987654321")
        XCTAssertFalse(registration.exists)
        XCTAssertFalse(registration.existsIsServed)
        XCTAssertEqual(registration.homeserver.baseURL, "https://matrix.br.gua.test")

        try VerifierStub.respond(path: "/resolve", status: 200, body: json(["homeserver": ref]))
        let login = try await client.resolve(phoneNumber: "+5511987654321")
        XCTAssertTrue(login.exists)
        XCTAssertFalse(login.existsIsServed)

        try VerifierStub.respond(path: "/resolve", status: 200, body: json(["exists": false, "registerAt": ref]))
        let served = try await client.resolve(phoneNumber: "+5511987654321")
        XCTAssertTrue(served.existsIsServed)
    }

    func testExistingAccountPlacementIsIndeterminate() async throws {
        try serveRoster(1)
        VerifierStub.respond(path: "/policy/routing", status: 404, body: "{}")
        let report = try await XCTUnwrap(makeVerifier(trustRoots: trustRoots(ofRoster: 1)).verify(resolution: answer(.br, exists: true), phoneNumber: "+5511987654321"))

        XCTAssertEqual(report.placement, .indeterminate)
        XCTAssertEqual(report.overall, .verified)
    }

    func testRedirectedHomeserverIsAFieldMismatch() async throws {
        try serveRoster(1)
        VerifierStub.respond(path: "/policy/routing", status: 404, body: "{}")
        let redirected = HomeserverResolution(exists: true,
                                              homeserver: ResolvedHomeserver(serverName: "br.gua.test", baseURL: "https://matrix.evil.test",
                                                                             masIssuer: "https://account.br.gua.test", region: nil))
        let report = try await XCTUnwrap(makeVerifier(trustRoots: trustRoots(ofRoster: 1)).verify(resolution: redirected, phoneNumber: "+5511987654321"))

        XCTAssertEqual(report.homeserverMatch, .fieldMismatch)
        XCTAssertEqual(report.memberEntry, .unverifiable)
        XCTAssertEqual(report.overall, .failed(.homeserverMatch))
    }

    // MARK: - The sign-in path

    func testStartVerificationReturnsBeforeTheReportExists() async {
        VerifierStub.hangs = true
        let verifier = makeVerifier(trustRoots: trustRoots(ofRoster: 0), budget: 1)

        verifier.startVerification(of: answer(.br), phoneNumber: "+5511987654321")

        XCTAssertNil(verifier.lastReport)
        let reported = expectation(description: "the hung roster request times out inside the budget")
        Task {
            while verifier.lastReport == nil {
                try await Task.sleep(for: .milliseconds(50))
            }
            reported.fulfill()
        }
        await fulfillment(of: [reported], timeout: 10)
        XCTAssertEqual(verifier.lastReport?.rosterSignature, .unverifiable(reason: "timeout"))
    }

    @MainActor
    func testSignInProceedsWhileVerificationIsStillRunning() async throws {
        VerifierStub.hangs = true
        let verifier = makeVerifier(trustRoots: trustRoots(ofRoster: 0), budget: 5)
        let windowManager = WindowManagerMock()
        windowManager.mainWindow = UIWindow()
        let appMediator = AppMediatorMock.default
        appMediator.underlyingWindowManager = windowManager
        let navigationRootCoordinator = NavigationRootCoordinator()
        let oidcPresenter = OIDCPresenterFake()
        let flowCoordinator = AuthenticationFlowCoordinator(authenticationService: AuthenticationService.mock,
                                                            bugReportService: BugReportServiceMock(.init()),
                                                            navigationRootCoordinator: navigationRootCoordinator,
                                                            appMediator: appMediator,
                                                            appSettings: ServiceLocator.shared.settings,
                                                            analytics: ServiceLocator.shared.analytics,
                                                            userIndicatorController: UserIndicatorControllerMock(),
                                                            resolverClient: ResolverClientFake(resolution: answer(.br, exists: true)),
                                                            resolverVerifier: verifier,
                                                            usesPhoneLoginHint: true) { _ in oidcPresenter }
        defer { oidcPresenter.finish() }

        flowCoordinator.start()
        let navigationStackCoordinator = try XCTUnwrap(navigationRootCoordinator.rootCoordinator as? NavigationStackCoordinator)
        let phoneEntry = try XCTUnwrap(navigationStackCoordinator.rootCoordinator as? PhoneEntryScreenCoordinator)
        phoneEntry.viewModel.context.localPhoneNumber = "5551234567"

        let signInStarted = deferFulfillment(oidcPresenter.authenticationStarted) { _ in true }
        phoneEntry.viewModel.context.send(viewAction: .continueTapped)
        try await signInStarted.fulfill()

        XCTAssertNil(verifier.lastReport, "sign-in reached the web session while the roster request was still hanging")
        XCTAssertEqual(VerifierStub.requestedPaths, ["/roster"])
    }

    // MARK: - Helpers

    private func makeVerifier(trustRoots: ResolverTrustRoots, budget: TimeInterval = 10) -> ResolverVerifier {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VerifierStubURLProtocol.self]
        let now = now
        return ResolverVerifier(baseURL: Self.baseURL, trustRoots: trustRoots, environment: "test", appSettings: appSettings,
                                checkpointStore: checkpoints, session: URLSession(configuration: configuration), budget: budget,
                                clock: { now })
    }

    private enum Answer {
        case br
    }

    private func answer(_ answer: Answer, exists: Bool = false) -> HomeserverResolution {
        HomeserverResolution(exists: exists,
                             homeserver: ResolvedHomeserver(serverName: "br.gua.test", baseURL: "https://matrix.br.gua.test",
                                                            masIssuer: "https://account.br.gua.test", region: "BR"))
    }

    private var rosters: [[String: Any]] {
        vectors["rosters"] as? [[String: Any]] ?? []
    }

    private var rosterRejections: [[String: Any]] {
        vectors["rosterRejections"] as? [[String: Any]] ?? []
    }

    private var policies: [[String: Any]] {
        vectors["policies"] as? [[String: Any]] ?? []
    }

    private var policyRejections: [[String: Any]] {
        vectors["policyRejections"] as? [[String: Any]] ?? []
    }

    private var log: [String: Any] {
        vectors["log"] as? [String: Any] ?? [:]
    }

    private func serveRoster(_ index: Int) throws {
        try VerifierStub.respond(path: "/roster", status: 200, body: json(rosters[index]["roster"]))
    }

    private func trustRoots(ofRoster index: Int, policy policyIndex: Int? = nil) -> ResolverTrustRoots {
        trustRoots(of: rosters[index], policy: policyIndex)
    }

    private func trustRoots(of rosterVector: [String: Any], policy policyIndex: Int? = nil) -> ResolverTrustRoots {
        let authority = keys(rosterVector["trustedKeys"])
        let policyKeys = policyIndex.map { keys(policies[$0]["trustedKeys"]) } ?? []
        return ResolverTrustRoots(authorityKeys: authority, authorityThreshold: rosterVector["threshold"] as? Int ?? 1,
                                  policyKeys: policyKeys, policyThreshold: 1)
    }

    private func keys(_ any: Any?) -> [ResolverTrustedKey] {
        (any as? [[String: Any]] ?? []).map { ResolverTrustedKey(id: $0["id"] as? String ?? "", publicKey: $0["publicKeySpkiB64"] as? String ?? "") }
    }

    private func logRoot(size: Int) -> String {
        (log["roots"] as? [[String: Any]] ?? []).first { $0["size"] as? Int == size }?["rootHex"] as? String ?? ""
    }

    private func consistencyProof(first: Int, second: Int) -> [String] {
        (log["consistencyProofs"] as? [[String: Any]] ?? [])
            .first { $0["first"] as? Int == first && $0["second"] as? Int == second }?["proof"] as? [String] ?? []
    }

    /// The `GET /roster/log` document for the vectors' seven events.
    private func logDocument() throws -> Data {
        let events = (log["events"] as? [[String: Any]] ?? []).map { event in
            ["index": event["index"] as Any, "type": event["type"] as Any, "homeserverId": event["homeserverId"] as Any,
             "payloadHash": event["payloadHash"] as Any, "recordedAt": event["recordedAt"] as Any]
        }
        return try json(["head": ["merkleRoot": logRoot(size: 7), "size": 7], "events": events])
    }

    private func json(_ object: Any?) throws -> Data {
        try JSONSerialization.data(withJSONObject: object as Any)
    }
}

// MARK: - Fakes

private final class InMemoryCheckpointStore: ResolverCheckpointStoring, @unchecked Sendable {
    private var checkpoints = [URL: RosterLogCheckpoint]()

    func checkpoint(for baseURL: URL) -> RosterLogCheckpoint? {
        checkpoints[baseURL]
    }

    func store(_ checkpoint: RosterLogCheckpoint, for baseURL: URL) {
        checkpoints[baseURL] = checkpoint
    }
}

private final class ResolverClientFake: ResolverClientProtocol, @unchecked Sendable {
    private let resolution: HomeserverResolution

    init(resolution: HomeserverResolution) {
        self.resolution = resolution
    }

    func resolve(phoneNumber: String) async throws -> HomeserverResolution {
        resolution
    }
}

@MainActor
private final class OIDCPresenterFake: OIDCAuthenticationPresenterProtocol {
    let authenticationStarted = PassthroughSubject<Void, Never>()
    private var pendingAuthentication: CheckedContinuation<Void, Never>?

    func authenticate(using oidcData: OIDCAuthorizationDataProxy) async -> Result<UserSessionProtocol, AuthenticationServiceError> {
        await withCheckedContinuation { continuation in
            pendingAuthentication = continuation
            authenticationStarted.send(())
        }
        return .failure(.oidcError(.userCancellation))
    }

    func cancel() { }

    func finish() {
        pendingAuthentication?.resume()
        pendingAuthentication = nil
    }
}

// MARK: - Stub transport

/// Canned responses by path. Tests run serially, so plain statics are safe here (the `ResolverClientTests` pattern).
private enum VerifierStub {
    struct Response {
        let status: Int
        let body: Data
    }

    static var responses = [String: Response]()
    static var requestedPaths = [String]()
    static var requestedQueries = [String: String]()
    static var failsTransport = false
    static var hangs = false

    static func respond(path: String, status: Int, body: String) {
        responses[path] = Response(status: status, body: Data(body.utf8))
    }

    static func respond(path: String, status: Int, body: Data) {
        responses[path] = Response(status: status, body: body)
    }

    static func reset() {
        responses = [:]
        requestedPaths = []
        requestedQueries = [:]
        failsTransport = false
        hangs = false
    }
}

private class VerifierStubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else { return }
        VerifierStub.requestedPaths.append(url.path)
        if let query = url.query { VerifierStub.requestedQueries[url.path] = query }
        if VerifierStub.hangs { return }
        if VerifierStub.failsTransport {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let canned = VerifierStub.responses[url.path] ?? VerifierStub.Response(status: 404, body: Data())
        guard let response = HTTPURLResponse(url: url, statusCode: canned.status, httpVersion: nil,
                                             headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: canned.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        // no-op
    }
}
