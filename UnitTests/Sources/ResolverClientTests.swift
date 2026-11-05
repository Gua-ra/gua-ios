//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

/// Coverage of the resolver v1 `POST /resolve` contract, mirroring Android's
/// `DefaultResolverClientTest`: request body assertions (including the routing-claims subject
/// binding), decision trace parsing, and problem-code mapping.
final class ResolverClientTests {
    private var client: ResolverClient!
    
    init() {
        ResolverStub.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResolverStubURLProtocol.self]
        client = ResolverClient(baseURL: URL(string: "https://resolver.example")!,
                                session: URLSession(configuration: configuration))
    }
    
    // MARK: - Legacy contract
    
    @Test
    func existingUserResolvesToTheLoginHomeserver() async throws {
        ResolverStub.respond(status: 200, body: """
        {
          "exists": true,
          "homeserver": { "serverName": "gua.global", "baseUrl": "https://matrix.gua.global", "masIssuer": "https://mas.gua.global", "region": "br" },
          "registerAt": { "serverName": "register.gua.global", "baseUrl": "https://register.gua.global" }
        }
        """)
        
        let resolution = try await client.resolve(phoneNumber: "+5511999999999")
        
        #expect(resolution.exists)
        #expect(resolution.homeserver.baseURL == "https://matrix.gua.global")
        #expect(resolution.homeserver.masIssuer == "https://mas.gua.global")
        #expect(resolution.trace == nil)
        
        // A plain resolve must keep the legacy single-field body byte for byte.
        let body = try #require(ResolverStub.lastRequestBody)
        #expect(String(data: body, encoding: .utf8) == #"{"phone":"+5511999999999"}"#)
    }
    
    @Test
    func newUserResolvesToTheRegisterHost() async throws {
        ResolverStub.respond(status: 200, body: """
        {
          "exists": false,
          "registerAt": { "serverName": "register.gua.global", "baseUrl": "https://register.gua.global" }
        }
        """)
        
        let resolution = try await client.resolve(phoneNumber: "+15551234567")
        
        #expect(!resolution.exists)
        #expect(resolution.homeserver.baseURL == "https://register.gua.global")
    }
    
    @Test
    func missingMatchingRefIsAMalformedResponse() async {
        ResolverStub.respond(status: 200, body: #"{ "exists": true }"#)
        
        await assertResolveThrows("+15551234567") { error in
            guard case .malformedResponse = error else {
                Issue.record("Expected malformedResponse, got \(error)")
                return
            }
        }
    }
    
    @Test
    func serverErrorIsSurfacedWithTheStatusCode() async {
        ResolverStub.respond(status: 502, body: "")
        
        await assertResolveThrows("+15551234567") { error in
            guard case let .server(status) = error else {
                Issue.record("Expected server error, got \(error)")
                return
            }
            #expect(status == 502)
            #expect(error.userFacingMessage == L10n.errorUnknown)
        }
    }
    
    // MARK: - v1 request fields
    
    @Test
    func optionalV1RoutingFieldsAreSentWhenProvided() async throws {
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
        
        let bodyData = try #require(ResolverStub.lastRequestBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        
        #expect(body["phone"] as? String == "+5511999999999")
        #expect(body["country"] as? String == "BR")
        #expect(body["mccmnc"] as? String == "72410")
        #expect(body["carrier"] as? String == "Vivo")
        #expect(body["regionHint"] as? String == "br-sp")
        #expect(body["affiliations"] as? [String] == ["example.edu"])
        #expect(body["attributes"] as? [String: String] == ["oidc_issuer": "https://sso.example.edu"])
        #expect(body["trace"] as? Bool == true)
        
        let claims = try #require(body["routingClaims"] as? [String: Any])
        #expect(claims["schemaVersion"] as? String == "gua-routing-claims.v1")
        #expect(claims["issuer"] as? String == "https://sso.example.edu")
        #expect(claims["audience"] as? String == "gua-resolver")
        #expect(claims["nonce"] as? String == "nonce-123")
        // Subject binding: the envelope is bound to the phone being resolved.
        #expect(claims["subject"] as? String == body["phone"] as? String)
        let signatures = try #require(claims["signatures"] as? [[String: Any]])
        #expect(signatures.count == 1)
        #expect(signatures[0]["keyId"] as? String == "sso-key-1")
        #expect(signatures[0]["signatureB64"] as? String == "abc123")
    }
    
    @Test
    func nilOptionsKeepTheLegacyBody() async throws {
        ResolverStub.respond(status: 200, body: """
        { "exists": false, "registerAt": { "serverName": "register.gua.global", "baseUrl": "https://register.gua.global" } }
        """)
        
        _ = try await client.resolve(phoneNumber: "+15551234567", options: ResolveOptions())
        
        let body = try #require(ResolverStub.lastRequestBody)
        #expect(String(data: body, encoding: .utf8) == #"{"phone":"+15551234567"}"#)
    }
    
    // MARK: - Decision trace
    
    @Test
    func traceIsParsedIncludingRosterVersion() async throws {
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
        
        let trace = try #require(resolution.trace)
        #expect(trace.source == "placement")
        #expect(trace.rule == "institution_domain")
        #expect(trace.ruleId == "rule-7")
        #expect(trace.reason == "affiliation matched delegated zone")
        #expect(trace.policyId == "policy-main")
        #expect(trace.policyVersion == 3)
        #expect(trace.delegatedZoneId == "zone-edu")
        #expect(trace.assignmentPolicy == "weighted")
        #expect(trace.homeserverId == "institution-br")
        #expect(trace.rosterVersion == 42)
    }
    
    // MARK: - Problem-code mapping
    
    @Test
    func invalidPhoneProblemMapsToTypedError() async {
        ResolverStub.respond(status: 400, body: #"{ "code": "invalid_phone", "message": "phone must be E.164" }"#)
        
        await assertResolveThrows("not-a-phone") { error in
            guard case .invalidPhone = error else {
                Issue.record("Expected invalidPhone, got \(error)")
                return
            }
            #expect(error.userFacingMessage == L10n.screenPhoneLoginInvalidNumber)
        }
    }
    
    @Test
    func invalidRoutingClaimsProblemMapsToTypedError() async {
        ResolverStub.respond(status: 400, body: #"{ "code": "invalid_routing_claims", "message": "subject mismatch" }"#)
        
        await assertResolveThrows("+15551234567") { error in
            guard case .invalidRoutingClaims = error else {
                Issue.record("Expected invalidRoutingClaims, got \(error)")
                return
            }
            #expect(error.userFacingMessage == UntranslatedL10n.guaResolverClaimsInvalid)
        }
    }
    
    @Test
    func directoryUnavailableProblemMapsToTypedError() async {
        ResolverStub.respond(status: 503, body: #"{ "code": "directory_unavailable", "message": "routing directory is temporarily unavailable" }"#)
        
        await assertResolveThrows("+15551234567") { error in
            guard case .directoryUnavailable(retryAfter: nil) = error else {
                Issue.record("Expected directoryUnavailable, got \(error)")
                return
            }
            #expect(error.userFacingMessage == UntranslatedL10n.guaResolverRoutingUnavailable)
        }
    }
    
    @Test
    func directoryUnavailableHonoursRetryAfter() async throws {
        ResolverStub.respond(status: 503,
                             body: #"{ "code": "directory_unavailable", "message": "routing directory is temporarily unavailable" }"#,
                             headers: ["Retry-After": "20"])
        let wait = try #require(ResolverError.formattedWait(20))
        
        await assertResolveThrows("+15551234567") { error in
            guard case .directoryUnavailable(retryAfter: 20?) = error else {
                Issue.record("Expected directoryUnavailable with a 20 s wait, got \(error)")
                return
            }
            #expect(error.userFacingMessage == UntranslatedL10n.guaResolverRoutingUnavailableRetryIn(wait))
        }
    }
    
    @Test
    func noPlacementAvailableProblemMapsToTypedError() async {
        ResolverStub.respond(status: 503, body: #"{ "code": "no_placement_available", "message": "no homeserver is currently accepting new accounts" }"#)
        
        await assertResolveThrows("+15551234567") { error in
            guard case .noPlacementAvailable = error else {
                Issue.record("Expected noPlacementAvailable, got \(error)")
                return
            }
            #expect(error.userFacingMessage == UntranslatedL10n.guaResolverRegistrationClosed)
        }
    }
    
    @Test
    func unknownProblemCodeFallsBackToServerError() async {
        ResolverStub.respond(status: 500, body: #"{ "code": "surprise", "message": "boom" }"#)
        
        await assertResolveThrows("+15551234567") { error in
            guard case let .server(status) = error else {
                Issue.record("Expected server error, got \(error)")
                return
            }
            #expect(status == 500)
        }
    }
    
    @Test
    func problemCopyIsDistinctPerCode() {
        let messages = [ResolverError.invalidPhone.userFacingMessage,
                        ResolverError.invalidRoutingClaims.userFacingMessage,
                        ResolverError.directoryUnavailable(retryAfter: nil).userFacingMessage,
                        ResolverError.noPlacementAvailable.userFacingMessage,
                        ResolverError.rateLimited(retryAfter: nil).userFacingMessage]
        #expect(Set(messages).count == messages.count)
        #expect(!messages.contains(L10n.errorUnknown))
    }
    
    // MARK: - Rate limiting and unavailability
    
    @Test
    func rateLimitedFromTheIngressHonoursRetryAfter() async throws {
        ResolverStub.respond(status: 429, body: "Too Many Requests", headers: ["Retry-After": "30"])
        let wait = try #require(ResolverError.formattedWait(30))
        
        await assertResolveThrows("+15551234567") { error in
            guard case .rateLimited(retryAfter: 30?) = error else {
                Issue.record("Expected rateLimited with a 30 s wait, got \(error)")
                return
            }
            #expect(error.userFacingMessage == UntranslatedL10n.guaResolverRateLimitedRetryIn(wait))
            #expect(error.userFacingMessage != L10n.screenPhoneLoginInvalidNumber)
        }
    }
    
    @Test
    func rateLimitedFromTheResolverHonoursRetryAfter() async {
        ResolverStub.respond(status: 429,
                             body: #"{"code":"rate_limited","message":"too many requests, retry after the Retry-After interval"}"#,
                             headers: ["Retry-After": "1"])
        
        await assertResolveThrows("+15551234567") { error in
            guard case .rateLimited(retryAfter: 1?) = error else {
                Issue.record("Expected rateLimited with a 1 s wait, got \(error)")
                return
            }
        }
    }
    
    @Test
    func rateLimitedWithoutRetryAfterAsksToWaitAMoment() async {
        ResolverStub.respond(status: 429, body: "")
        
        await assertResolveThrows("+15551234567") { error in
            guard case .rateLimited(retryAfter: nil) = error else {
                Issue.record("Expected rateLimited without a wait, got \(error)")
                return
            }
            #expect(error.userFacingMessage == UntranslatedL10n.guaResolverRateLimited)
        }
    }
    
    @Test
    func unavailableWithoutACodeHonoursRetryAfter() async throws {
        ResolverStub.respond(status: 503, body: "Service Unavailable", headers: ["Retry-After": "90"])
        let wait = try #require(ResolverError.formattedWait(90))
        
        await assertResolveThrows("+15551234567") { error in
            guard case .temporarilyUnavailable(retryAfter: 90?) = error else {
                Issue.record("Expected temporarilyUnavailable with a 90 s wait, got \(error)")
                return
            }
            #expect(error.userFacingMessage == UntranslatedL10n.guaResolverRoutingUnavailableRetryIn(wait))
        }
    }
    
    @Test
    func unreadableRetryAfterFallsBackToAMoment() async {
        ResolverStub.respond(status: 503, body: "", headers: ["Retry-After": "soon"])
        
        await assertResolveThrows("+15551234567") { error in
            guard case .temporarilyUnavailable(retryAfter: nil) = error else {
                Issue.record("Expected temporarilyUnavailable without a wait, got \(error)")
                return
            }
            #expect(error.userFacingMessage == UntranslatedL10n.guaResolverRoutingUnavailable)
        }
    }
    
    @Test
    func httpDateRetryAfterIsMeasuredFromTheDateHeader() async {
        defer { Bundle.overrideLocalizations = nil }
        Bundle.overrideLocalizations = ["en"]
        ResolverStub.respond(status: 429, body: "", headers: ["Date": "Wed, 21 Oct 2026 07:26:30 GMT",
                                                              "Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"])
        
        await assertResolveThrows("+15551234567") { error in
            guard case .rateLimited(retryAfter: 90?) = error else {
                Issue.record("Expected rateLimited with a 90 s wait, got \(error)")
                return
            }
            #expect(error.userFacingMessage == UntranslatedL10n.guaResolverRateLimitedRetryIn("2 minutes"))
        }
    }
    
    @Test
    func retryAfterParsing() throws {
        let retryAt = try #require(ISO8601DateFormatter().date(from: "2026-10-21T07:28:00Z"))
        let fortyFiveSecondsEarlier = retryAt.addingTimeInterval(-45)
        
        #expect(try retryAfter(["Retry-After": "120"], now: retryAt) == 120)
        #expect(try retryAfter(["Retry-After": " 0 "], now: retryAt) == 0)
        #expect(try (retryAfter([:], now: retryAt)) == nil)
        #expect(try (retryAfter(["Retry-After": ""], now: retryAt)) == nil)
        #expect(try (retryAfter(["Retry-After": "-5"], now: retryAt)) == nil)
        #expect(try (retryAfter(["Retry-After": "1.5"], now: retryAt)) == nil)
        #expect(try (retryAfter(["Retry-After": "99999999999999999999999"], now: retryAt)) == nil)
        
        #expect(try retryAfter(["Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"], now: fortyFiveSecondsEarlier) == 45)
        #expect(try retryAfter(["Retry-After": "Wednesday, 21-Oct-26 07:28:00 GMT"], now: fortyFiveSecondsEarlier) == 45)
        #expect(try retryAfter(["Retry-After": "Wed Oct 21 07:28:00 2026"], now: fortyFiveSecondsEarlier) == 45)
        #expect(try retryAfter(["Retry-After": "Thu Oct  1 07:28:00 2026"], now: retryAt.addingTimeInterval(-20 * 86400 - 45)) == 45)
        #expect(try (retryAfter(["Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"], now: retryAt)) == nil)
        #expect(try (retryAfter(["Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"], now: retryAt.addingTimeInterval(60))) == nil)
    }
    
    @Test
    func onlyInvalidPhoneAsksToFixTheNumber() async {
        for (status, body) in [(400, ""), (403, ""), (404, #"{ "code": "not_found" }"#), (422, "")] {
            ResolverStub.respond(status: status, body: body)
            
            await assertResolveThrows("+15551234567") { error in
                guard case .server(status) = error else {
                    Issue.record("Expected a plain server error for \(status), got \(error)")
                    return
                }
                #expect(error.userFacingMessage == L10n.errorUnknown)
            }
        }
    }
    
    @Test
    func formattedWaitRoundsUpInEnglish() {
        defer { Bundle.overrideLocalizations = nil }
        Bundle.overrideLocalizations = ["en"]
        #expect(ResolverError.formattedWait(nil) == nil)
        #expect(ResolverError.formattedWait(0) == nil)
        #expect(ResolverError.formattedWait(0.4) == ResolverError.formattedWait(1))
        #expect(ResolverError.formattedWait(61) == ResolverError.formattedWait(120))
        #expect(ResolverError.formattedWait(60) != ResolverError.formattedWait(61))
        #expect(ResolverError.formattedWait(1) == "1 second")
        #expect(ResolverError.formattedWait(30) == "30 seconds")
        #expect(ResolverError.formattedWait(60) == "1 minute")
        #expect(ResolverError.formattedWait(.infinity) == nil)
    }
    
    @Test
    func formattedWaitUsesTheAppLanguage() {
        defer { Bundle.overrideLocalizations = nil }
        Bundle.overrideLocalizations = ["pt-BR"]
        
        #expect(ResolverError.formattedWait(30) == "30 segundos")
        #expect(ResolverError.formattedWait(90) == "2 minutos")
    }
    
    // MARK: - Private
    
    private func retryAfter(_ headers: [String: String], now: Date) throws -> TimeInterval? {
        let url = try #require(URL(string: "https://resolver.example"))
        let response = try #require(HTTPURLResponse(url: url,
                                                    statusCode: 429,
                                                    httpVersion: nil,
                                                    headerFields: headers))
        return ResolverClient.retryAfter(of: response, now: now)
    }
    
    private func assertResolveThrows(_ phoneNumber: String,
                                     sourceLocation: SourceLocation = #_sourceLocation,
                                     validate: (ResolverError) -> Void) async {
        do {
            _ = try await client.resolve(phoneNumber: phoneNumber)
            Issue.record("Expected resolve to throw", sourceLocation: sourceLocation)
        } catch let error as ResolverError {
            validate(error)
        } catch {
            Issue.record("Expected a ResolverError, got \(error)", sourceLocation: sourceLocation)
        }
    }
}

// MARK: - Stub transport

/// Canned resolver responses plus capture of the outgoing request body. Tests run serially, so plain
/// statics are safe here (same pattern as `BugReportServiceTests`).
private nonisolated enum ResolverStub {
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var responseBody = Data()
    nonisolated(unsafe) static var responseHeaders: [String: String] = [:]
    nonisolated(unsafe) static var lastRequestBody: Data?
    
    static func respond(status: Int, body: String, headers: [String: String] = [:]) {
        statusCode = status
        responseBody = Data(body.utf8)
        responseHeaders = headers
    }
    
    static func reset() {
        statusCode = 200
        responseBody = Data()
        responseHeaders = [:]
        lastRequestBody = nil
    }
}

private nonisolated class ResolverStubURLProtocol: URLProtocol {
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
                                             headerFields: ["Content-Type": "application/json"].merging(ResolverStub.responseHeaders) { $1 }) else { return }
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
