//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import XCTest

/// Coverage of the resolver v1 `POST /resolve` contract, mirroring Android's
/// `DefaultResolverClientTest`: request body assertions (including the routing-claims subject
/// binding), decision trace parsing, and problem-code mapping.
final class ResolverClientTests: XCTestCase {
    private var client: ResolverClient!

    override func setUp() {
        super.setUp()
        ResolverStub.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResolverStubURLProtocol.self]
        client = ResolverClient(baseURL: URL(string: "https://resolver.example")!,
                                session: URLSession(configuration: configuration))
    }

    // MARK: - Legacy contract

    func testExistingUserResolvesToTheLoginHomeserver() async throws {
        ResolverStub.respond(status: 200, body: """
        {
          "exists": true,
          "homeserver": { "serverName": "gua.global", "baseUrl": "https://matrix.gua.global", "masIssuer": "https://mas.gua.global", "region": "br" },
          "registerAt": { "serverName": "register.gua.global", "baseUrl": "https://register.gua.global" }
        }
        """)

        let resolution = try await client.resolve(phoneNumber: "+5511999999999")

        XCTAssertTrue(resolution.exists)
        XCTAssertEqual(resolution.homeserver.baseURL, "https://matrix.gua.global")
        XCTAssertEqual(resolution.homeserver.masIssuer, "https://mas.gua.global")
        XCTAssertNil(resolution.trace)

        // A plain resolve must keep the legacy single-field body byte for byte.
        let body = try XCTUnwrap(ResolverStub.lastRequestBody)
        XCTAssertEqual(String(data: body, encoding: .utf8), #"{"phone":"+5511999999999"}"#)
    }

    func testNewUserResolvesToTheRegisterHost() async throws {
        ResolverStub.respond(status: 200, body: """
        {
          "exists": false,
          "registerAt": { "serverName": "register.gua.global", "baseUrl": "https://register.gua.global" }
        }
        """)

        let resolution = try await client.resolve(phoneNumber: "+15551234567")

        XCTAssertFalse(resolution.exists)
        XCTAssertEqual(resolution.homeserver.baseURL, "https://register.gua.global")
    }

    func testMissingMatchingRefIsAMalformedResponse() async {
        ResolverStub.respond(status: 200, body: #"{ "exists": true }"#)

        await assertResolveThrows("+15551234567") { error in
            guard case .malformedResponse = error else {
                return XCTFail("Expected malformedResponse, got \(error)")
            }
        }
    }

    func testServerErrorIsSurfacedWithTheStatusCode() async {
        ResolverStub.respond(status: 503, body: "")

        await assertResolveThrows("+15551234567") { error in
            guard case let .server(status) = error else {
                return XCTFail("Expected server error, got \(error)")
            }
            XCTAssertEqual(status, 503)
        }
    }

    // MARK: - v1 request fields

    func testOptionalV1RoutingFieldsAreSentWhenProvided() async throws {
        ResolverStub.respond(status: 200, body: """
        {
          "exists": false,
          "registerAt": { "serverName": "institution.gua.global", "baseUrl": "https://institution.gua.global" },
          "trace": { "source": "placement", "rule": "institution_domain", "homeserverId": "institution-br", "rosterVersion": 42 }
        }
        """)

        let options = ResolveOptions(country: "BR",
                                     mccmnc: "72410",
                                     carrier: "Vivo",
                                     regionHint: "br-sp",
                                     affiliations: ["example.edu"],
                                     attributes: ["oidc_issuer": "https://sso.example.edu"],
                                     routingClaims: RoutingClaimsEnvelope(schemaVersion: "gua-routing-claims.v1",
                                                                          issuer: "https://sso.example.edu",
                                                                          audience: "gua-resolver",
                                                                          issuedAt: "2026-07-04T12:00:00Z",
                                                                          expiresAt: "2026-07-04T12:05:00Z",
                                                                          nonce: "nonce-123",
                                                                          subject: "+5511999999999",
                                                                          affiliations: ["example.edu"],
                                                                          attributes: ["institution_domain": "example.edu"],
                                                                          signatures: [ClaimSignature(keyId: "sso-key-1",
                                                                                                      signatureB64: "abc123")]),
                                     trace: true)

        _ = try await client.resolve(phoneNumber: "+5511999999999", options: options)

        let bodyData = try XCTUnwrap(ResolverStub.lastRequestBody)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])

        XCTAssertEqual(body["phone"] as? String, "+5511999999999")
        XCTAssertEqual(body["country"] as? String, "BR")
        XCTAssertEqual(body["mccmnc"] as? String, "72410")
        XCTAssertEqual(body["carrier"] as? String, "Vivo")
        XCTAssertEqual(body["regionHint"] as? String, "br-sp")
        XCTAssertEqual(body["affiliations"] as? [String], ["example.edu"])
        XCTAssertEqual(body["attributes"] as? [String: String], ["oidc_issuer": "https://sso.example.edu"])
        XCTAssertEqual(body["trace"] as? Bool, true)

        let claims = try XCTUnwrap(body["routingClaims"] as? [String: Any])
        XCTAssertEqual(claims["schemaVersion"] as? String, "gua-routing-claims.v1")
        XCTAssertEqual(claims["issuer"] as? String, "https://sso.example.edu")
        XCTAssertEqual(claims["audience"] as? String, "gua-resolver")
        XCTAssertEqual(claims["nonce"] as? String, "nonce-123")
        // Subject binding: the envelope is bound to the phone being resolved.
        XCTAssertEqual(claims["subject"] as? String, body["phone"] as? String)
        let signatures = try XCTUnwrap(claims["signatures"] as? [[String: Any]])
        XCTAssertEqual(signatures.count, 1)
        XCTAssertEqual(signatures[0]["keyId"] as? String, "sso-key-1")
        XCTAssertEqual(signatures[0]["signatureB64"] as? String, "abc123")
    }

    func testNilOptionsKeepTheLegacyBody() async throws {
        ResolverStub.respond(status: 200, body: """
        { "exists": false, "registerAt": { "serverName": "register.gua.global", "baseUrl": "https://register.gua.global" } }
        """)

        _ = try await client.resolve(phoneNumber: "+15551234567", options: ResolveOptions())

        let body = try XCTUnwrap(ResolverStub.lastRequestBody)
        XCTAssertEqual(String(data: body, encoding: .utf8), #"{"phone":"+15551234567"}"#)
    }

    // MARK: - Decision trace

    func testTraceIsParsedIncludingRosterVersion() async throws {
        ResolverStub.respond(status: 200, body: """
        {
          "exists": false,
          "registerAt": { "serverName": "institution.gua.global", "baseUrl": "https://institution.gua.global" },
          "trace": {
            "source": "placement",
            "rule": "institution_domain",
            "ruleId": "rule-7",
            "reason": "affiliation matched delegated zone",
            "policyId": "policy-main",
            "policyVersion": 3,
            "delegatedZoneId": "zone-edu",
            "assignmentPolicy": "weighted",
            "homeserverId": "institution-br",
            "rosterVersion": 42
          }
        }
        """)

        let resolution = try await client.resolve(phoneNumber: "+5511999999999",
                                                  options: ResolveOptions(trace: true))

        let trace = try XCTUnwrap(resolution.trace)
        XCTAssertEqual(trace.source, "placement")
        XCTAssertEqual(trace.rule, "institution_domain")
        XCTAssertEqual(trace.ruleId, "rule-7")
        XCTAssertEqual(trace.reason, "affiliation matched delegated zone")
        XCTAssertEqual(trace.policyId, "policy-main")
        XCTAssertEqual(trace.policyVersion, 3)
        XCTAssertEqual(trace.delegatedZoneId, "zone-edu")
        XCTAssertEqual(trace.assignmentPolicy, "weighted")
        XCTAssertEqual(trace.homeserverId, "institution-br")
        XCTAssertEqual(trace.rosterVersion, 42)
    }

    // MARK: - Problem-code mapping

    func testInvalidPhoneProblemMapsToTypedError() async {
        ResolverStub.respond(status: 400, body: #"{ "code": "invalid_phone", "message": "phone must be E.164" }"#)

        await assertResolveThrows("not-a-phone") { error in
            guard case .invalidPhone = error else {
                return XCTFail("Expected invalidPhone, got \(error)")
            }
            XCTAssertEqual(error.userFacingMessage, L10n.screenPhoneLoginInvalidNumber)
        }
    }

    func testInvalidRoutingClaimsProblemMapsToTypedError() async {
        ResolverStub.respond(status: 400, body: #"{ "code": "invalid_routing_claims", "message": "subject mismatch" }"#)

        await assertResolveThrows("+15551234567") { error in
            guard case .invalidRoutingClaims = error else {
                return XCTFail("Expected invalidRoutingClaims, got \(error)")
            }
            XCTAssertEqual(error.userFacingMessage, UntranslatedL10n.guaResolverClaimsInvalid)
        }
    }

    func testDirectoryUnavailableProblemMapsToTypedError() async {
        ResolverStub.respond(status: 503, body: #"{ "code": "directory_unavailable", "message": "routing directory is temporarily unavailable" }"#)

        await assertResolveThrows("+15551234567") { error in
            guard case .directoryUnavailable = error else {
                return XCTFail("Expected directoryUnavailable, got \(error)")
            }
            XCTAssertEqual(error.userFacingMessage, UntranslatedL10n.guaResolverRoutingUnavailable)
        }
    }

    func testNoPlacementAvailableProblemMapsToTypedError() async {
        ResolverStub.respond(status: 503, body: #"{ "code": "no_placement_available", "message": "no homeserver is currently accepting new accounts" }"#)

        await assertResolveThrows("+15551234567") { error in
            guard case .noPlacementAvailable = error else {
                return XCTFail("Expected noPlacementAvailable, got \(error)")
            }
            XCTAssertEqual(error.userFacingMessage, UntranslatedL10n.guaResolverRegistrationClosed)
        }
    }

    func testUnknownProblemCodeFallsBackToServerError() async {
        ResolverStub.respond(status: 500, body: #"{ "code": "surprise", "message": "boom" }"#)

        await assertResolveThrows("+15551234567") { error in
            guard case let .server(status) = error else {
                return XCTFail("Expected server error, got \(error)")
            }
            XCTAssertEqual(status, 500)
        }
    }

    func testProblemCopyIsDistinctPerCode() {
        let messages = [ResolverError.invalidRoutingClaims.userFacingMessage,
                        ResolverError.directoryUnavailable.userFacingMessage,
                        ResolverError.noPlacementAvailable.userFacingMessage]
        XCTAssertEqual(Set(messages).count, messages.count)
        XCTAssertFalse(messages.contains(L10n.errorUnknown))
    }

    // MARK: - Private

    private func assertResolveThrows(_ phoneNumber: String,
                                     file: StaticString = #filePath,
                                     line: UInt = #line,
                                     validate: (ResolverError) -> Void) async {
        do {
            _ = try await client.resolve(phoneNumber: phoneNumber)
            XCTFail("Expected resolve to throw", file: file, line: line)
        } catch let error as ResolverError {
            validate(error)
        } catch {
            XCTFail("Expected a ResolverError, got \(error)", file: file, line: line)
        }
    }
}

// MARK: - Stub transport

/// Canned resolver responses plus capture of the outgoing request body. Tests run serially, so plain
/// statics are safe here (same pattern as `BugReportServiceTests`).
private enum ResolverStub {
    static var statusCode = 200
    static var responseBody = Data()
    static var lastRequestBody: Data?

    static func respond(status: Int, body: String) {
        statusCode = status
        responseBody = Data(body.utf8)
    }

    static func reset() {
        statusCode = 200
        responseBody = Data()
        lastRequestBody = nil
    }
}

private class ResolverStubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else { return }
        ResolverStub.lastRequestBody = Self.bodyData(of: request)

        guard let response = HTTPURLResponse(url: url,
                                             statusCode: ResolverStub.statusCode,
                                             httpVersion: nil,
                                             headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: ResolverStub.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        // no-op
    }

    /// By the time a request reaches a `URLProtocol` its body is only available as a stream.
    private static func bodyData(of request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
