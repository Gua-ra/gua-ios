//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

/// The stub's responses are shared, so the tests can't run in parallel.
@Suite(.serialized)
final class RoomStateClientTests {
    init() {
        RoomStateHTTPStub.reset()
    }
    
    @Test
    func requestsTheEventWithTheSessionToken() async throws {
        RoomStateHTTPStub.respond(status: 200, body: #"{"type":"global.gua.room.background","state_key":"","event_id":"$abc","origin_server_ts":1730000000123,"sender":"@a:gua.global","content":{"v":1,"kind":"preset","preset":"sky"}}"#)
        
        let result = await makeClient().chatBackground(roomID: "!room:gua.global")
        
        let request = try #require(RoomStateHTTPStub.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.host() == "matrix.gua.global")
        #expect(request.url?.query() == "format=event")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        #expect(request.timeoutInterval == 15)
        
        guard case .found(let value) = result else {
            Issue.record("Expected the event, got \(result)")
            return
        }
        #expect(value.eventID == "$abc")
        #expect(value.timestamp == 1_730_000_000_123)
        #expect(ChatTheme(contentJSON: value.contentJSON) == ChatTheme(wallpaper: .preset(.sky)))
    }
    
    @Test
    func pathEscapesTheRoomIDAndEndsWithTheEmptyStateKey() throws {
        #expect(try RoomStateClient.path(roomID: "!room:gua.global") == "/_matrix/client/v3/rooms/!room:gua.global/state/global.gua.room.background/")
        // Room v12 IDs carry no server name and can hold any URL-safe base64 character.
        #expect(try RoomStateClient.path(roomID: "!Yx8_r-2Lq9/aB+c?d#e") == "/_matrix/client/v3/rooms/!Yx8_r-2Lq9%2FaB+c%3Fd%23e/state/global.gua.room.background/")
    }
    
    @Test
    func v12RoomIDReachesTheServerUnchanged() async throws {
        RoomStateHTTPStub.respond(status: 404, body: #"{"errcode":"M_NOT_FOUND"}"#)
        
        _ = await makeClient().chatBackground(roomID: "!3sSfKD9cZ7hZvZ5-Z6Y0rVbH9c5dlK6vxA7WlAxp_ZY")
        
        let url = try #require(RoomStateHTTPStub.requests.first?.url)
        #expect(url.path(percentEncoded: true) == "/_matrix/client/v3/rooms/!3sSfKD9cZ7hZvZ5-Z6Y0rVbH9c5dlK6vxA7WlAxp_ZY/state/global.gua.room.background/")
    }
    
    @Test
    func bareContentHasNoEventAndTimestampZero() async {
        RoomStateHTTPStub.respond(status: 200, body: #"{"v":1,"kind":"preset","preset":"night"}"#)
        
        let result = await makeClient().chatBackground(roomID: "!room:gua.global")
        
        guard case .found(let value) = result else {
            Issue.record("Expected the content, got \(result)")
            return
        }
        #expect(value.eventID == nil)
        #expect(value.timestamp == 0)
        #expect(ChatTheme(contentJSON: value.contentJSON) == ChatTheme(wallpaper: .preset(.night)))
    }
    
    @Test
    func notFoundMeansNoBackground() async {
        RoomStateHTTPStub.respond(status: 404, body: #"{"errcode":"M_NOT_FOUND"}"#)
        let result = await makeClient().chatBackground(roomID: "!room:gua.global")
        guard case .notFound = result else {
            Issue.record("Expected no background, got \(result)")
            return
        }
    }
    
    @Test
    func unauthorizedNeverSignsOut() async {
        RoomStateHTTPStub.respond(status: 401, body: #"{"errcode":"M_UNKNOWN_TOKEN"}"#)
        let result = await makeClient().chatBackground(roomID: "!room:gua.global")
        guard case .failed(.unauthorized) = result else {
            Issue.record("Expected unauthorized, got \(result)")
            return
        }
    }
    
    @Test
    func serverErrorFails() async {
        RoomStateHTTPStub.respond(status: 500, body: "")
        let result = await makeClient().chatBackground(roomID: "!room:gua.global")
        guard case .failed(.server(status: 500)) = result else {
            Issue.record("Expected a server error, got \(result)")
            return
        }
    }
    
    @Test
    func unreadableBodyFails() async {
        RoomStateHTTPStub.respond(status: 200, body: "<html>")
        let result = await makeClient().chatBackground(roomID: "!room:gua.global")
        guard case .failed(.decoding) = result else {
            Issue.record("Expected a decoding error, got \(result)")
            return
        }
    }
    
    @Test
    func missingTokenSendsNothing() async {
        let client = RoomStateClient(session: RoomStateHTTPStub.makeSession(), homeserver: { "https://matrix.gua.global" }, accessToken: { nil })
        let result = await client.chatBackground(roomID: "!room:gua.global")
        guard case .failed(.missingAccessToken) = result else {
            Issue.record("Expected a missing token, got \(result)")
            return
        }
        #expect(RoomStateHTTPStub.requests.isEmpty)
    }
    
    private func makeClient() -> RoomStateClient {
        RoomStateClient(session: RoomStateHTTPStub.makeSession(), homeserver: { "https://matrix.gua.global/" }, accessToken: { "token" })
    }
}

private final nonisolated class RoomStateHTTPStub: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var recordedRequests: [URLRequest] = []
    private nonisolated(unsafe) static var response: (status: Int, body: String) = (404, "{}")
    
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
