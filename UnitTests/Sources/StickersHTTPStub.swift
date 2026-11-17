//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Synchronization

/// Answers every request by its path, and records them. Shared state, so each suite resets it in `init`.
final nonisolated class StickersHTTPStub: URLProtocol {
    struct Response {
        var status = 200
        var body = Data()
        var headers: [String: String] = [:]
    }
    
    private struct State {
        var requests: [URLRequest] = []
        var responses: [String: Response] = [:]
    }
    
    private static let state = Mutex(State())
    
    static var requests: [URLRequest] {
        state.withLock { $0.requests }
    }
    
    static func reset() {
        state.withLock { $0 = State() }
    }
    
    static func respond(path: String, status: Int = 200, body: String, headers: [String: String] = [:]) {
        respond(path: path, response: Response(status: status, body: Data(body.utf8), headers: headers))
    }
    
    static func respond(path: String, response: Response) {
        state.withLock { $0.responses[path] = response }
    }
    
    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StickersHTTPStub.self]
        return configuration
    }
    
    override static func canInit(with request: URLRequest) -> Bool {
        true
    }
    
    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }
    
    override func startLoading() {
        guard let url = request.url else { return }
        let response = Self.state.withLock { state in
            state.requests.append(request)
            return state.responses[url.path()] ?? Response(status: 404)
        }
        if let httpResponse = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers) {
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    
    override func stopLoading() { }
}
