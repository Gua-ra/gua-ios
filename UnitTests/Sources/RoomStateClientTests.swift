//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import XCTest

final class RoomStateClientTests: XCTestCase {
    override func setUp() {
        RoomStateHTTPStub.reset()
    }

    func testRequestsTheEventWithTheSessionToken() async throws {
        RoomStateHTTPStub.respond(status: 200, body: #"{"type":"global.gua.room.background","state_key":"","event_id":"$abc","origin_server_ts":1730000000123,"sender":"@a:gua.global","content":{"v":1,"kind":"preset","preset":"sky"}}"#)

        let result = await makeClient().chatBackground(roomID: "!room:gua.global")

        let request = try XCTUnwrap(RoomStateHTTPStub.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.host(), "matrix.gua.global")
        XCTAssertEqual(request.url?.query(), "format=event")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
        XCTAssertEqual(request.timeoutInterval, 15)

        guard case .found(let value) = result else {
            XCTFail("Expected the event, got \(result)")
            return
        }
        XCTAssertEqual(value.eventID, "$abc")
        XCTAssertEqual(value.timestamp, 1_730_000_000_123)
        XCTAssertEqual(ChatBackground(contentJSON: value.contentJSON), .preset(.sky))
    }

    func testPathEscapesTheRoomIDAndEndsWithTheEmptyStateKey() throws {
        XCTAssertEqual(try RoomStateClient.path(roomID: "!room:gua.global"),
                       "/_matrix/client/v3/rooms/!room:gua.global/state/global.gua.room.background/")
        // Room v12 IDs carry no server name and can hold any URL-safe base64 character.
        XCTAssertEqual(try RoomStateClient.path(roomID: "!Yx8_r-2Lq9/aB+c?d#e"),
                       "/_matrix/client/v3/rooms/!Yx8_r-2Lq9%2FaB+c%3Fd%23e/state/global.gua.room.background/")
    }

    func testV12RoomIDReachesTheServerUnchanged() async throws {
        RoomStateHTTPStub.respond(status: 404, body: #"{"errcode":"M_NOT_FOUND"}"#)

        _ = await makeClient().chatBackground(roomID: "!3sSfKD9cZ7hZvZ5-Z6Y0rVbH9c5dlK6vxA7WlAxp_ZY")

        let url = try XCTUnwrap(RoomStateHTTPStub.requests.first?.url)
        XCTAssertEqual(url.path(percentEncoded: true),
                       "/_matrix/client/v3/rooms/!3sSfKD9cZ7hZvZ5-Z6Y0rVbH9c5dlK6vxA7WlAxp_ZY/state/global.gua.room.background/")
    }

    func testBareContentHasNoEventAndTimestampZero() async {
        RoomStateHTTPStub.respond(status: 200, body: #"{"v":1,"kind":"preset","preset":"night"}"#)

        let result = await makeClient().chatBackground(roomID: "!room:gua.global")

        guard case .found(let value) = result else {
            XCTFail("Expected the content, got \(result)")
            return
        }
        XCTAssertNil(value.eventID)
        XCTAssertEqual(value.timestamp, 0)
        XCTAssertEqual(ChatBackground(contentJSON: value.contentJSON), .preset(.night))
    }

    func testNotFoundMeansNoBackground() async {
        RoomStateHTTPStub.respond(status: 404, body: #"{"errcode":"M_NOT_FOUND"}"#)
        let result = await makeClient().chatBackground(roomID: "!room:gua.global")
        XCTAssertEqual(result, .notFound)
    }

    func testUnauthorizedNeverSignsOut() async {
        RoomStateHTTPStub.respond(status: 401, body: #"{"errcode":"M_UNKNOWN_TOKEN"}"#)
        let result = await makeClient().chatBackground(roomID: "!room:gua.global")
        XCTAssertEqual(result, .failed(.unauthorized))
    }

    func testServerErrorFails() async {
        RoomStateHTTPStub.respond(status: 500, body: "")
        let result = await makeClient().chatBackground(roomID: "!room:gua.global")
        XCTAssertEqual(result, .failed(.server(status: 500)))
    }

    func testMissingTokenSendsNothing() async {
        let client = RoomStateClient(session: RoomStateHTTPStub.makeSession(), homeserver: { "https://matrix.gua.global" }, accessToken: { nil })
        let result = await client.chatBackground(roomID: "!room:gua.global")
        XCTAssertEqual(result, .failed(.missingAccessToken))
        XCTAssertTrue(RoomStateHTTPStub.requests.isEmpty)
    }

    private func makeClient() -> RoomStateClient {
        RoomStateClient(session: RoomStateHTTPStub.makeSession(), homeserver: { "https://matrix.gua.global/" }, accessToken: { "token" })
    }
}

private final class RoomStateHTTPStub: URLProtocol {
    private static let lock = NSLock()
    private static var recordedRequests: [URLRequest] = []
    private static var response: (status: Int, body: String) = (404, "{}")

    static var requests: [URLRequest] {
        lock.withLock { recordedRequests }
    }

    static func respond(status: Int, body: String) {
        lock.withLock { response = (status, body) }
    }

    static func reset() {
        lock.withLock {
            recordedRequests = []
            response = (404, "{}")
        }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RoomStateHTTPStub.self]
        return URLSession(configuration: configuration)
    }

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else { return }
        let response = Self.lock.withLock {
            Self.recordedRequests.append(request)
            return Self.response
        }
        let httpResponse = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])
        if let httpResponse {
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: Data(response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}
