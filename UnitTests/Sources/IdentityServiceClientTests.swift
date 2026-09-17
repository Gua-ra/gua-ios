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

    /// The tag the call sites send, from the locale a Brazilian device actually reports. It is the
    /// helper's own output that is pinned here: a hand-written tag would only prove the header is
    /// forwarded, which it always was, and not that what the device produces matches a template.
    func testTheDeviceLanguageIsAskedForAsABCP47Tag() {
        XCTAssertEqual(Locale.guaLanguageTag(for: Locale(identifier: "pt_BR")), "pt-BR")
        XCTAssertEqual(Locale.guaLanguageTag(for: Locale(identifier: "en_US")), "en-US")
        // A locale that names no region, and one that carries a calendar: neither shape may reach
        // the server with anything the first '-' does not leave as a language it knows.
        XCTAssertEqual(Locale.guaLanguageTag(for: Locale(identifier: "fr")), "fr")
        XCTAssertEqual(Locale.guaLanguageTag(for: Locale(identifier: "pt_BR@calendar=buddhist")), "pt-BR")
    }

    // MARK: - The number the screens resolve before they spend an attempt

    /// The resolver the three reauth screens share. Its job is to refuse what the server cannot
    /// read while accepting everything it can, and the shape that matters most is the punctuated
    /// one: the reauth fields declare `.textContentType(.telephoneNumber)`, so AutoFill hands them
    /// the number exactly as Contacts stores it. A guard that refused that would dead-end
    /// deactivation and identity reset for a number the account really is on.
    func testAPunctuatedNumberResolvesToTheDigitsAndTheRestIsRefused() {
        XCTAssertEqual(GuaPhoneNumber.e164(from: "+1 (415) 555-0143"), "+14155550143")
        XCTAssertEqual(GuaPhoneNumber.e164(from: "+55 11 98888-7777"), "+5511988887777")
        XCTAssertEqual(GuaPhoneNumber.e164(from: " +1-415-555-0143 "), "+14155550143")
        XCTAssertEqual(GuaPhoneNumber.e164(from: "+14155550143"), "+14155550143")

        // No country code, letters, and a number too short or too long to be one: still refused,
        // because each of those costs an attempt and earns a refusal that cannot name the reason.
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

    /// The number goes out again with the code: the server stores nothing between the two calls, so
    /// a token can only be minted by someone who can produce both.
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

    /// The refusal is one sentence whatever the body says. The server's own message is a single
    /// English constant, so carrying it through would show English to everybody; the local string
    /// is the same single constant per language, which is what keeps the refusal identical for a
    /// number nobody has, a number somebody else has, and a number that is simply not this
    /// account's.
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

        let url = try await client.startPinEnrollment(accessToken: "access-token")

        XCTAssertEqual(url, URL(string: "https://identity.example/login/enroll/token"))
        let request = try XCTUnwrap(IdentityServiceStub.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/security/pin/enroll/start")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
        // The enrollment page is the one call site that reads the language itself, so it is checked
        // here rather than at a caller.
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Language"), Locale.guaLanguageTag())
    }

    func testStartingPinEnrollmentOnAnAccountThatAlreadyHasOneSaysSo() async throws {
        IdentityServiceStub.respond(status: 409, body: #"{ "code": "pin_already_set", "message": "This account already has a PIN." }"#)

        do {
            _ = try await client.startPinEnrollment(accessToken: "access-token")
            XCTFail("Expected the conflict to throw")
        } catch IdentityServiceError.pinAlreadySet {
            // The expected refusal.
        }
    }

    /// The same conflict for the other factor. The server's sentence is English whoever reads it,
    /// so the screen corrects the row from the local string instead.
    func testStartingPasskeyEnrollmentOnAnAccountThatAlreadyHasOneSaysWhich() async throws {
        IdentityServiceStub.respond(status: 409, body: #"{ "code": "passkey_already_registered", "message": "This account already has a passkey." }"#)

        do {
            _ = try await client.startPasskeyEnrollment(accessToken: "access-token")
            XCTFail("Expected the conflict to throw")
        } catch let error as IdentityServiceError {
            guard case .passkeyAlreadyRegistered = error else {
                XCTFail("Expected the conflict, got \(error)")
                return
            }
            XCTAssertEqual(error.errorDescription, L10n.screenTwoStepVerificationPasskeyAlreadySet)
        }
    }

    /// A passkey-only account on a deployment with passkeys turned off holds nothing it can prove
    /// here, so no factor can be added at all. That is the one enrollment refusal with somewhere
    /// else to send the reader: the delayed recovery.
    func testAnAccountWithNoProofItCanRunIsPointedAtRecovery() async throws {
        IdentityServiceStub.respond(status: 409, body: #"{ "code": "step_up_unavailable" }"#)

        do {
            _ = try await client.startPinEnrollment(accessToken: "access-token")
            XCTFail("Expected the conflict to throw")
        } catch let error as IdentityServiceError {
            guard case .stepUpUnavailable = error else {
                XCTFail("Expected the conflict, got \(error)")
                return
            }
            XCTAssertEqual(error.errorDescription, L10n.screenTwoStepVerificationStepUpUnavailable)
        }
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
    /// `URLProtocol` hands the body over as a stream and leaves `httpBody` nil, so it is read once
    /// on the way through and kept here.
    static var lastBody = Data()

    static func lastBodyObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: lastBody) as? [String: Any])
    }

    static func respond(status: Int, body: String) {
        statusCode = status
        responseBody = Data(body.utf8)
    }

    static func reset() {
        statusCode = 200
        responseBody = Data()
        lastRequest = nil
        lastBody = Data()
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
