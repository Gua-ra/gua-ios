//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

/// Coverage of the account slices of identity-service this app talks to: the fields
/// `GET /security/pin/status` adds for a live recovery, `POST /security/recovery/cancel`,
/// reauthentication by phone digest, and factor enrollment.
@MainActor
final class IdentityServiceClientTests {
    private var client: IdentityServiceClient!
    
    init() {
        IdentityServiceStub.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IdentityServiceStubURLProtocol.self]
        client = IdentityServiceClient(baseURL: URL(string: "https://identity.example")!,
                                       session: URLSession(configuration: configuration))
    }
    
    // MARK: - Security status
    
    @Test
    func securityStatusDecodesAPendingAccountRecovery() async throws {
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
        
        #expect(status.pendingAccountRecovery == PendingAccountRecovery(completableAt: Date(timeIntervalSince1970: 1_800_000_000),
                                                                        expiresAt: Date(timeIntervalSince1970: 1_800_604_800)))
    }
    
    @Test
    func securityStatusFromAServerWithoutRecoveryFieldsHasNothingPending() async throws {
        IdentityServiceStub.respond(status: 200, body: #"{ "hasPin": false }"#)
        
        let status = try await client.securityStatus(accessToken: "access-token")
        
        #expect(!status.hasPin)
        #expect(status.pendingAccountRecovery == nil)
    }
    
    @Test
    func securityStatusWithNoLiveRecoveryHasNothingPending() async throws {
        IdentityServiceStub.respond(status: 200, body: """
        {
          "hasPin": true,
          "accountRecoveryPending": false,
          "accountRecoveryCompletableAtEpochSeconds": null,
          "accountRecoveryExpiresAtEpochSeconds": null
        }
        """)
        
        let status = try await client.securityStatus(accessToken: "access-token")
        
        #expect(status.pendingAccountRecovery == nil)
    }
    
    @Test
    func securityStatusKeepsAPendingRecoveryWhoseDatesAreMissing() async throws {
        IdentityServiceStub.respond(status: 200, body: #"{ "hasPin": true, "accountRecoveryPending": true }"#)
        
        let status = try await client.securityStatus(accessToken: "access-token")
        
        #expect(status.pendingAccountRecovery == PendingAccountRecovery(completableAt: nil, expiresAt: nil))
    }
    
    // MARK: - The language the code is written in
    
    @Test
    func theAppLanguageIsAskedForAsABCP47Tag() {
        defer { Bundle.overrideLocalizations = nil }
        
        for language in ["pt-BR", "es", "fr", "en"] {
            Bundle.overrideLocalizations = [language]
            #expect(Bundle.guaAppLanguage == language)
        }
        Bundle.overrideLocalizations = ["pt"]
        #expect(Bundle.guaAppLanguage == "pt-BR")
        Bundle.overrideLocalizations = nil
        #expect(["en", "pt-BR", "es", "fr"].contains(Bundle.guaAppLanguage))
    }
    
    // MARK: - The number the screens resolve before they spend an attempt
    
    /// The resolver the three reauth screens share. Its job is to refuse what the server cannot
    /// read while accepting everything it can, and the shape that matters most is the punctuated
    /// one: the reauth fields declare `.textContentType(.telephoneNumber)`, so AutoFill hands them
    /// the number exactly as Contacts stores it. A guard that refused that would dead-end
    /// deactivation and identity reset for a number the account really is on.
    @Test
    func aPunctuatedNumberResolvesToTheDigitsAndTheRestIsRefused() {
        #expect(GuaPhoneNumber.e164(from: "+1 (415) 555-0143") == "+14155550143")
        #expect(GuaPhoneNumber.e164(from: "+55 11 98888-7777") == "+5511988887777")
        #expect(GuaPhoneNumber.e164(from: " +1-415-555-0143 ") == "+14155550143")
        #expect(GuaPhoneNumber.e164(from: "+14155550143") == "+14155550143")
        
        // No country code, letters, and a number too short or too long to be one: still refused,
        // because each of those costs an attempt and earns a refusal that cannot name the reason.
        #expect(GuaPhoneNumber.e164(from: "4155550143") == nil)
        #expect(GuaPhoneNumber.e164(from: "+1 (415) CALL-NOW") == nil)
        #expect(GuaPhoneNumber.e164(from: "+1234567") == nil)
        #expect(GuaPhoneNumber.e164(from: "+1234567890123456") == nil)
        #expect(GuaPhoneNumber.e164(from: "") == nil)
    }
    
    // MARK: - Reauthentication by phone digest
    
    @Test
    func startingReauthSubmitsTheNumberAndAcceptsA202() async throws {
        IdentityServiceStub.respond(status: 202, body: "")
        
        try await client.startAccountReauth(accessToken: "access-token",
                                            phone: "+14155550143",
                                            language: "pt-BR")
        
        let request = try #require(IdentityServiceStub.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/account/reauth/start")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
        #expect(request.value(forHTTPHeaderField: "Accept-Language") == "pt-BR")
        #expect(try IdentityServiceStub.lastBodyObject()["phone"] as? String == "+14155550143")
    }
    
    /// The number goes out again with the code: the server stores nothing between the two calls, so
    /// a token can only be minted by someone who can produce both.
    @Test
    func verifyingReauthSubmitsTheNumberTheCodeAndTheOperation() async throws {
        IdentityServiceStub.respond(status: 200, body: #"{ "reauthToken": "token", "expiresInSeconds": 300 }"#)
        
        let token = try await client.verifyAccountReauth(accessToken: "access-token",
                                                         phone: "+14155550143",
                                                         code: "123456",
                                                         operation: .phoneChange)
        
        #expect(token == "token")
        let body = try IdentityServiceStub.lastBodyObject()
        #expect(body["phone"] as? String == "+14155550143")
        #expect(body["code"] as? String == "123456")
        #expect(body["operation"] as? String == "PHONE_CHANGE")
    }
    
    /// The refusal is one sentence whatever the body says. The server's own message is a single
    /// English constant, so carrying it through would show English to everybody; the local string
    /// is the same single constant per language, which is what keeps the refusal identical for a
    /// number nobody has, a number somebody else has, and a number that is simply not this
    /// account's.
    @Test
    func aWrongNumberSurfacesTheLocalNeutralRefusal() async throws {
        let bodies = [#"{ "code": "reauth_phone_mismatch", "message": "That is not the number on your account." }"#,
                      #"{ "code": "reauth_phone_mismatch" }"#]
        
        for body in bodies {
            IdentityServiceStub.respond(status: 403, body: body)
            
            do {
                try await client.startAccountReauth(accessToken: "access-token", phone: "+14155550199", language: nil)
                Issue.record("Expected the mismatch to throw")
            } catch let error as IdentityServiceError {
                guard case .reauthPhoneMismatch = error else {
                    Issue.record("Expected the mismatch, got \(error)")
                    return
                }
                #expect(error.errorDescription == L10n.screenAccountReauthPhoneMismatch)
            }
        }
    }
    
    @Test
    func aNumberTheNormalizerCannotReadIsItsOwnRefusal() async throws {
        IdentityServiceStub.respond(status: 400, body: #"{ "code": "invalid_phone_number", "message": "Could not parse." }"#)
        
        do {
            try await client.startAccountReauth(accessToken: "access-token", phone: "nonsense", language: nil)
            Issue.record("Expected the refusal to throw")
        } catch IdentityServiceError.invalidPhoneNumber {
            // The expected refusal.
        }
    }
    
    // MARK: - Factor enrollment
    
    @Test
    func startingPinEnrollmentReturnsTheOneTimeURL() async throws {
        IdentityServiceStub.respond(status: 200, body: #"{ "enrollUrl": "https://identity.example/login/enroll/token" }"#)
        
        let url = try await client.startPinEnrollment(accessToken: "access-token", redirectURI: nil)
        
        #expect(url == URL(string: "https://identity.example/login/enroll/token"))
        let request = try #require(IdentityServiceStub.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/security/pin/enroll/start")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
        // The enrollment page is the one call site that reads the language itself, so it is checked
        // here rather than at a caller.
        #expect(request.value(forHTTPHeaderField: "Accept-Language") == Bundle.guaAppLanguage)
    }
    
    @Test
    func startingPinEnrollmentOnAnAccountThatAlreadyHasOneSaysSo() async throws {
        IdentityServiceStub.respond(status: 409, body: #"{ "code": "pin_already_set", "message": "This account already has a PIN." }"#)
        
        do {
            _ = try await client.startPinEnrollment(accessToken: "access-token", redirectURI: nil)
            Issue.record("Expected the conflict to throw")
        } catch IdentityServiceError.pinAlreadySet {
            // The expected refusal.
        }
    }
    
    /// The same conflict for the other factor. The server's sentence is English whoever reads it,
    /// so the screen corrects the row from the local string instead.
    @Test
    func startingPasskeyEnrollmentOnAnAccountThatAlreadyHasOneSaysWhich() async throws {
        IdentityServiceStub.respond(status: 409, body: #"{ "code": "passkey_already_registered", "message": "This account already has a passkey." }"#)
        
        do {
            _ = try await client.startPasskeyEnrollment(accessToken: "access-token", redirectURI: nil)
            Issue.record("Expected the conflict to throw")
        } catch let error as IdentityServiceError {
            guard case .passkeyAlreadyRegistered = error else {
                Issue.record("Expected the conflict, got \(error)")
                return
            }
            #expect(error.errorDescription == L10n.screenTwoStepVerificationPasskeyAlreadySet)
        }
    }
    
    /// A passkey-only account on a deployment with passkeys turned off holds nothing it can prove
    /// here, so no factor can be added at all. That is the one enrollment refusal with somewhere
    /// else to send the reader: the delayed recovery.
    @Test
    func anAccountWithNoProofItCanRunIsPointedAtRecovery() async throws {
        IdentityServiceStub.respond(status: 409, body: #"{ "code": "step_up_unavailable" }"#)
        
        do {
            _ = try await client.startPinEnrollment(accessToken: "access-token", redirectURI: nil)
            Issue.record("Expected the conflict to throw")
        } catch let error as IdentityServiceError {
            guard case .stepUpUnavailable = error else {
                Issue.record("Expected the conflict, got \(error)")
                return
            }
            #expect(error.errorDescription == L10n.screenTwoStepVerificationStepUpUnavailable)
        }
    }
    
    // MARK: - The enrollment redirect
    
    /// A named redirect is what sends the sheet back to the build it was opened from. The QA and
    /// debug builds answer to schemes the release build does not, so without it every enrollment
    /// returns to whichever one the deployment happens to have configured.
    @Test
    func enrollmentAsksToReturnToThisBuildsRedirect() async throws {
        IdentityServiceStub.respond(status: 200, body: #"{ "enrollUrl": "https://identity.example/login/enroll/token" }"#)
        
        _ = try await client.startPasskeyEnrollment(accessToken: "access-token", redirectURI: "global.gua.dev:/oidc")
        
        #expect(try IdentityServiceStub.lastBodyObject()["redirectUri"] as? String == "global.gua.dev:/oidc")
    }
    
    /// Naming nothing keeps the field off the wire entirely, which is what a server too old to know
    /// it needs to see.
    @Test
    func enrollmentWithNoRedirectNamesNone() async throws {
        IdentityServiceStub.respond(status: 200, body: #"{ "enrollUrl": "https://identity.example/login/enroll/token" }"#)
        
        _ = try await client.startPinEnrollment(accessToken: "access-token", redirectURI: nil)
        
        #expect(try (IdentityServiceStub.lastBodyObject()["redirectUri"]) == nil)
    }
    
    /// The deployment keeps the allowlist, so a build can always be holding a scheme this server
    /// has not been told about (an older server, or one whose config has not caught up). That must
    /// never be where enrollment ends: the call goes out once more with nothing named, which is
    /// what every build did before the field existed, and the factor still gets added.
    @Test
    func aRefusedRedirectIsAskedAgainWithoutOneRatherThanFailing() async throws {
        IdentityServiceStub.respond(inOrder: [(400, #"{ "code": "invalid_redirect_uri", "message": "Not allowed." }"#),
                                              (200, #"{ "enrollUrl": "https://identity.example/login/enroll/token" }"#)])
        
        let url = try await client.startPinEnrollment(accessToken: "access-token", redirectURI: "global.gua.debug:/oidc")
        
        #expect(url == URL(string: "https://identity.example/login/enroll/token"))
        #expect(IdentityServiceStub.sentBodies.count == 2)
        #expect(try IdentityServiceStub.bodyObject(at: 0)["redirectUri"] as? String == "global.gua.debug:/oidc")
        #expect(try (IdentityServiceStub.bodyObject(at: 1)["redirectUri"]) == nil)
    }
    
    /// Once, and only once. A server that refuses the call with no redirect in it is refusing
    /// something other than the redirect, and asking a third time would only spend the account's
    /// allowance on the same answer.
    @Test
    func aRefusedRedirectIsNotAskedAgainMoreThanOnce() async throws {
        IdentityServiceStub.respond(status: 400, body: #"{ "code": "invalid_redirect_uri" }"#)
        
        do {
            _ = try await client.startPinEnrollment(accessToken: "access-token", redirectURI: "global.gua.debug:/oidc")
            Issue.record("Expected the second refusal to throw")
        } catch IdentityServiceError.invalidRedirectURI {
            // The expected refusal, and the reader never sees the deployment's English for it.
        }
        
        #expect(IdentityServiceStub.sentBodies.count == 2)
    }
    
    // MARK: - Cancel
    
    @Test
    func cancelAccountRecoveryPostsWithTheBearerToken() async throws {
        IdentityServiceStub.respond(status: 204, body: "")
        
        try await client.cancelAccountRecovery(accessToken: "access-token")
        
        let request = try #require(IdentityServiceStub.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/security/recovery/cancel")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
    }
    
    @Test
    func cancelAccountRecoveryRefusalThrows() async {
        IdentityServiceStub.respond(status: 500, body: #"{ "code": "internal_error" }"#)
        
        do {
            try await client.cancelAccountRecovery(accessToken: "access-token")
            Issue.record("Expected the cancel to throw")
        } catch let IdentityServiceError.server(status, _) {
            #expect(status == 500)
        } catch {
            Issue.record("Expected a server error, got \(error)")
        }
    }
}

// MARK: - Stub transport

/// Canned responses plus capture of the outgoing request. Tests run serially, so plain statics are
/// safe here (same pattern as `ResolverClientTests`).
private nonisolated enum IdentityServiceStub {
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var responseBody = Data()
    nonisolated(unsafe) static var lastRequest: URLRequest?
    /// `URLProtocol` hands the body over as a stream and leaves `httpBody` nil, so it is read once
    /// on the way through and kept here.
    nonisolated(unsafe) static var lastBody = Data()
    /// Answers for a call that makes more than one request, taken in order. Empty means every
    /// request gets the single canned response above.
    nonisolated(unsafe) static var queuedResponses: [(status: Int, body: Data)] = []
    /// Every body that went out, so a test can say what the second attempt asked for.
    nonisolated(unsafe) static var sentBodies: [Data] = []
    
    static func lastBodyObject() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: lastBody) as? [String: Any])
    }
    
    static func bodyObject(at index: Int) throws -> [String: Any] {
        let body = try #require(sentBodies[safe: index])
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }
    
    static func respond(status: Int, body: String) {
        statusCode = status
        responseBody = Data(body.utf8)
    }
    
    static func respond(inOrder responses: [(status: Int, body: String)]) {
        queuedResponses = responses.map { ($0.status, Data($0.body.utf8)) }
    }
    
    static func reset() {
        statusCode = 200
        responseBody = Data()
        lastRequest = nil
        lastBody = Data()
        queuedResponses = []
        sentBodies = []
    }
}

private nonisolated extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private nonisolated class IdentityServiceStubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }
    
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }
    
    override func startLoading() {
        guard let url = request.url else { return }
        IdentityServiceStub.lastRequest = request
        IdentityServiceStub.lastBody = request.httpBody ?? Self.readBody(of: request)
        IdentityServiceStub.sentBodies.append(IdentityServiceStub.lastBody)
        
        let answer = IdentityServiceStub.queuedResponses.isEmpty
            ? (status: IdentityServiceStub.statusCode, body: IdentityServiceStub.responseBody)
            : IdentityServiceStub.queuedResponses.removeFirst()
        
        guard let response = HTTPURLResponse(url: url,
                                             statusCode: answer.status,
                                             httpVersion: nil,
                                             headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    
    override func stopLoading() {
        // no-op
    }
    
    private static func readBody(of request: URLRequest) -> Data {
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(contentsOf: buffer[0..<read])
        }
        return data
    }
}
