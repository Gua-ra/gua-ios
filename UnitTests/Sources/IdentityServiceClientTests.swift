//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import XCTest

/// Coverage of the account recovery slice of identity-service: the fields `GET /security/pin/status`
/// adds for a live recovery, and `POST /security/recovery/cancel`.
@MainActor
final class IdentityServiceClientTests: XCTestCase {
    private var client: IdentityServiceClient!

    override func setUp() {
        super.setUp()
        IdentityServiceStub.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IdentityServiceStubURLProtocol.self]
        client = IdentityServiceClient(baseURL: URL(string: "https://identity.example")!,
                                       session: URLSession(configuration: configuration))
    }

    // MARK: - Security status

    func testSecurityStatusDecodesAPendingAccountRecovery() async throws {
        IdentityServiceStub.respond(status: 200, body: """
        {
          "hasPin": true,
          "passkeyRegistered": false,
          "accountRecoveryPending": true,
          "accountRecoveryCompletableAtEpochSeconds": 1800000000,
          "accountRecoveryExpiresAtEpochSeconds": 1800604800
        }
        """)

        let status = try await client.securityStatus(accessToken: "access-token")

        XCTAssertEqual(status.pendingAccountRecovery,
                       PendingAccountRecovery(completableAt: Date(timeIntervalSince1970: 1_800_000_000),
                                              expiresAt: Date(timeIntervalSince1970: 1_800_604_800)))
    }

    func testSecurityStatusFromAServerWithoutRecoveryFieldsHasNothingPending() async throws {
        IdentityServiceStub.respond(status: 200, body: #"{ "hasPin": false }"#)

        let status = try await client.securityStatus(accessToken: "access-token")

        XCTAssertFalse(status.hasPin)
        XCTAssertNil(status.pendingAccountRecovery)
    }

    func testSecurityStatusWithNoLiveRecoveryHasNothingPending() async throws {
        IdentityServiceStub.respond(status: 200, body: """
        {
          "hasPin": true,
          "accountRecoveryPending": false,
          "accountRecoveryCompletableAtEpochSeconds": null,
          "accountRecoveryExpiresAtEpochSeconds": null
        }
        """)

        let status = try await client.securityStatus(accessToken: "access-token")

        XCTAssertNil(status.pendingAccountRecovery)
    }

    func testSecurityStatusKeepsAPendingRecoveryWhoseDatesAreMissing() async throws {
        IdentityServiceStub.respond(status: 200, body: #"{ "hasPin": true, "accountRecoveryPending": true }"#)

        let status = try await client.securityStatus(accessToken: "access-token")

        XCTAssertEqual(status.pendingAccountRecovery, PendingAccountRecovery(completableAt: nil, expiresAt: nil))
    }

    // MARK: - Cancel

    func testCancelAccountRecoveryPostsWithTheBearerToken() async throws {
        IdentityServiceStub.respond(status: 204, body: "")

        try await client.cancelAccountRecovery(accessToken: "access-token")

        let request = try XCTUnwrap(IdentityServiceStub.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/security/recovery/cancel")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
    }

    func testCancelAccountRecoveryRefusalThrows() async {
        IdentityServiceStub.respond(status: 500, body: #"{ "code": "internal_error" }"#)

        do {
            try await client.cancelAccountRecovery(accessToken: "access-token")
            XCTFail("Expected the cancel to throw")
        } catch let IdentityServiceError.server(status, _) {
            XCTAssertEqual(status, 500)
        } catch {
            XCTFail("Expected a server error, got \(error)")
        }
    }
}

// MARK: - Stub transport

/// Canned responses plus capture of the outgoing request. Tests run serially, so plain statics are
/// safe here (same pattern as `ResolverClientTests`).
private enum IdentityServiceStub {
    static var statusCode = 200
    static var responseBody = Data()
    static var lastRequest: URLRequest?

    static func respond(status: Int, body: String) {
        statusCode = status
        responseBody = Data(body.utf8)
    }

    static func reset() {
        statusCode = 200
        responseBody = Data()
        lastRequest = nil
    }
}

private class IdentityServiceStubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else { return }
        IdentityServiceStub.lastRequest = request

        guard let response = HTTPURLResponse(url: url,
                                             statusCode: IdentityServiceStub.statusCode,
                                             httpVersion: nil,
                                             headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: IdentityServiceStub.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        // no-op
    }
}
