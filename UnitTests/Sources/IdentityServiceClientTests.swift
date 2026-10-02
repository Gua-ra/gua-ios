//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import XCTest

/// Coverage of the account slices of identity-service this app talks to: the fields
/// `GET /security/pin/status` adds for a live recovery, `POST /security/recovery/cancel`,
/// reauthentication by phone digest, and factor enrollment.
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

    // MARK: - The language the code is written in

    /// Pins the helper's own output for the locale a Brazilian device reports. A hand-written tag
    /// would only prove the header is forwarded.
    func testTheDeviceLanguageIsAskedForAsABCP47Tag() {
        XCTAssertEqual(Locale.guaLanguageTag(for: Locale(identifier: "pt_BR")), "pt-BR")
        XCTAssertEqual(Locale.guaLanguageTag(for: Locale(identifier: "en_US")), "en-US")
        XCTAssertEqual(Locale.guaLanguageTag(for: Locale(identifier: "fr")), "fr")
        XCTAssertEqual(Locale.guaLanguageTag(for: Locale(identifier: "pt_BR@calendar=buddhist")), "pt-BR")
    }

    // MARK: - The number the screens resolve before they spend an attempt

    /// The resolver the three reauth screens share. It must accept the punctuated shape AutoFill
    /// supplies from Contacts and refuse what the server cannot read.
    func testAPunctuatedNumberResolvesToTheDigitsAndTheRestIsRefused() {
        XCTAssertEqual(GuaPhoneNumber.e164(from: "+1 (415) 555-0143"), "+14155550143")
        XCTAssertEqual(GuaPhoneNumber.e164(from: "+55 11 98888-7777"), "+5511988887777")
        XCTAssertEqual(GuaPhoneNumber.e164(from: " +1-415-555-0143 "), "+14155550143")
        XCTAssertEqual(GuaPhoneNumber.e164(from: "+14155550143"), "+14155550143")

        // No country code, letters, too short or too long: refused, because each would cost a reauth
        // attempt.
        XCTAssertNil(GuaPhoneNumber.e164(from: "4155550143"))
        XCTAssertNil(GuaPhoneNumber.e164(from: "+1 (415) CALL-NOW"))
        XCTAssertNil(GuaPhoneNumber.e164(from: "+1234567"))
        XCTAssertNil(GuaPhoneNumber.e164(from: "+1234567890123456"))
        XCTAssertNil(GuaPhoneNumber.e164(from: ""))
    }

    // MARK: - Reauthentication by phone digest

    func testStartingReauthSubmitsTheNumberAndAcceptsA202() async throws {
        IdentityServiceStub.respond(status: 202, body: "")

        try await client.startAccountReauth(accessToken: "access-token",
                                            phone: "+14155550143",
                                            language: Locale.guaLanguageTag(for: Locale(identifier: "pt_BR")))

        let request = try XCTUnwrap(IdentityServiceStub.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/account/reauth/start")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Language"), "pt-BR")
        XCTAssertEqual(try IdentityServiceStub.lastBodyObject()["phone"] as? String, "+14155550143")
    }

    /// The number goes out again with the code: the server stores nothing between the two calls.
    func testVerifyingReauthSubmitsTheNumberTheCodeAndTheOperation() async throws {
        IdentityServiceStub.respond(status: 200, body: #"{ "reauthToken": "token", "expiresInSeconds": 300 }"#)

        let token = try await client.verifyAccountReauth(accessToken: "access-token",
                                                         phone: "+14155550143",
                                                         code: "123456",
                                                         operation: .phoneChange)

        XCTAssertEqual(token, "token")
        let body = try IdentityServiceStub.lastBodyObject()
        XCTAssertEqual(body["phone"] as? String, "+14155550143")
        XCTAssertEqual(body["code"] as? String, "123456")
        XCTAssertEqual(body["operation"] as? String, "PHONE_CHANGE")
    }

    /// The refusal is one localized sentence whatever the body says, so it is identical for a number
    /// nobody has, a number somebody else has, and a number that is not this account's.
    func testAWrongNumberSurfacesTheLocalNeutralRefusal() async throws {
        let bodies = [#"{ "code": "reauth_phone_mismatch", "message": "That is not the number on your account." }"#,
                      #"{ "code": "reauth_phone_mismatch" }"#]

        for body in bodies {
            IdentityServiceStub.respond(status: 403, body: body)

            do {
                try await client.startAccountReauth(accessToken: "access-token", phone: "+14155550199", language: nil)
                XCTFail("Expected the mismatch to throw")
            } catch let error as IdentityServiceError {
                guard case .reauthPhoneMismatch = error else {
                    XCTFail("Expected the mismatch, got \(error)")
                    return
                }
                XCTAssertEqual(error.errorDescription, L10n.screenAccountReauthPhoneMismatch)
            }
        }
    }

    func testANumberTheNormalizerCannotReadIsItsOwnRefusal() async throws {
        IdentityServiceStub.respond(status: 400, body: #"{ "code": "invalid_phone_number", "message": "Could not parse." }"#)

        do {
            try await client.startAccountReauth(accessToken: "access-token", phone: "nonsense", language: nil)
            XCTFail("Expected the refusal to throw")
        } catch IdentityServiceError.invalidPhoneNumber {
            // The expected refusal.
        }
    }

    // MARK: - Factor enrollment

    func testStartingPinEnrollmentReturnsTheOneTimeURL() async throws {
        IdentityServiceStub.respond(status: 200, body: #"{ "enrollUrl": "https://identity.example/login/enroll/token" }"#)

        let url = try await client.startPinEnrollment(accessToken: "access-token", redirectURI: nil)

        XCTAssertEqual(url, URL(string: "https://identity.example/login/enroll/token"))
        let request = try XCTUnwrap(IdentityServiceStub.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/security/pin/enroll/start")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
        // The enrollment call reads the language itself, so it is checked here rather than at a caller.
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Language"), Locale.guaLanguageTag())
    }

    func testStartingPinEnrollmentOnAnAccountThatAlreadyHasOneSaysSo() async throws {
        IdentityServiceStub.respond(status: 409, body: #"{ "code": "pin_already_set", "message": "This account already has a PIN." }"#)

        do {
            _ = try await client.startPinEnrollment(accessToken: "access-token", redirectURI: nil)
            XCTFail("Expected the conflict to throw")
        } catch IdentityServiceError.pinAlreadySet {
            // The expected refusal.
        }
    }

    func testStartingPasskeyEnrollmentOnAnAccountThatAlreadyHasOneSaysWhich() async throws {
        IdentityServiceStub.respond(status: 409, body: #"{ "code": "passkey_already_registered", "message": "This account already has a passkey." }"#)

        do {
            _ = try await client.startPasskeyEnrollment(accessToken: "access-token", redirectURI: nil)
            XCTFail("Expected the conflict to throw")
        } catch let error as IdentityServiceError {
            guard case .passkeyAlreadyRegistered = error else {
                XCTFail("Expected the conflict, got \(error)")
                return
            }
            XCTAssertEqual(error.errorDescription, L10n.screenTwoStepVerificationPasskeyAlreadySet)
        }
    }

    /// A passkey-only account on a deployment with passkeys off can add no factor. The refusal points
    /// at the delayed recovery.
    func testAnAccountWithNoProofItCanRunIsPointedAtRecovery() async throws {
        IdentityServiceStub.respond(status: 409, body: #"{ "code": "step_up_unavailable" }"#)

        do {
            _ = try await client.startPinEnrollment(accessToken: "access-token", redirectURI: nil)
            XCTFail("Expected the conflict to throw")
        } catch let error as IdentityServiceError {
            guard case .stepUpUnavailable = error else {
                XCTFail("Expected the conflict, got \(error)")
                return
            }
            XCTAssertEqual(error.errorDescription, L10n.screenTwoStepVerificationStepUpUnavailable)
        }
    }

    // MARK: - The enrollment redirect

    /// A named redirect sends the sheet back to the build it was opened from. The QA and debug builds
    /// answer to schemes the release build does not.
    func testEnrollmentAsksToReturnToThisBuildsRedirect() async throws {
        IdentityServiceStub.respond(status: 200, body: #"{ "enrollUrl": "https://identity.example/login/enroll/token" }"#)

        _ = try await client.startPasskeyEnrollment(accessToken: "access-token", redirectURI: "global.gua.dev:/oidc")

        XCTAssertEqual(try IdentityServiceStub.lastBodyObject()["redirectUri"] as? String, "global.gua.dev:/oidc")
    }

    /// Naming nothing keeps the field off the wire entirely, which is what a server too old to know
    /// it needs to see.
    func testEnrollmentWithNoRedirectNamesNone() async throws {
        IdentityServiceStub.respond(status: 200, body: #"{ "enrollUrl": "https://identity.example/login/enroll/token" }"#)

        _ = try await client.startPinEnrollment(accessToken: "access-token", redirectURI: nil)

        XCTAssertNil(try IdentityServiceStub.lastBodyObject()["redirectUri"])
    }

    /// A build can hold a scheme the deployment has not allowlisted. Enrollment must not end there:
    /// the call goes out once more with no redirect.
    func testARefusedRedirectIsAskedAgainWithoutOneRatherThanFailing() async throws {
        IdentityServiceStub.respond(inOrder: [(400, #"{ "code": "invalid_redirect_uri", "message": "Not allowed." }"#),
                                              (200, #"{ "enrollUrl": "https://identity.example/login/enroll/token" }"#)])

        let url = try await client.startPinEnrollment(accessToken: "access-token", redirectURI: "global.gua.debug:/oidc")

        XCTAssertEqual(url, URL(string: "https://identity.example/login/enroll/token"))
        XCTAssertEqual(IdentityServiceStub.sentBodies.count, 2)
        XCTAssertEqual(try IdentityServiceStub.bodyObject(at: 0)["redirectUri"] as? String, "global.gua.debug:/oidc")
        XCTAssertNil(try IdentityServiceStub.bodyObject(at: 1)["redirectUri"])
    }

    /// Once only: a server that also refuses the call without a redirect is refusing something else.
    func testARefusedRedirectIsNotAskedAgainMoreThanOnce() async throws {
        IdentityServiceStub.respond(status: 400, body: #"{ "code": "invalid_redirect_uri" }"#)

        do {
            _ = try await client.startPinEnrollment(accessToken: "access-token", redirectURI: "global.gua.debug:/oidc")
            XCTFail("Expected the second refusal to throw")
        } catch IdentityServiceError.invalidRedirectURI {
            // The expected refusal.
        }

        XCTAssertEqual(IdentityServiceStub.sentBodies.count, 2)
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

/// Tests run serially, so plain statics are safe.
private enum IdentityServiceStub {
    static var statusCode = 200
    static var responseBody = Data()
    static var lastRequest: URLRequest?
    /// `URLProtocol` hands the body over as a stream and leaves `httpBody` nil.
    static var lastBody = Data()
    /// Consumed in order; empty means every request gets the single canned response.
    static var queuedResponses: [(status: Int, body: Data)] = []
    /// Every body that went out, so a test can say what the second attempt asked for.
    static var sentBodies: [Data] = []

    static func lastBodyObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: lastBody) as? [String: Any])
    }

    static func bodyObject(at index: Int) throws -> [String: Any] {
        let body = try XCTUnwrap(sentBodies[safe: index])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
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

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
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
