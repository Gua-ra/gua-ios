//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum ClientServerError: Error, Equatable {
    case invalidURL
    case missingAccessToken
    /// The SDK refreshes the token on its own, so a 401 only skips this attempt and never signs out.
    case unauthorized
    case server(status: Int)
    case transport
    case decoding
}

enum ClientServerHTTP {
    static func makeRequest(homeserver: String, path: String, method: String, accessToken: String, body: Data? = nil) throws(ClientServerError) -> URLRequest {
        var base = homeserver
        while base.hasSuffix("/") {
            base.removeLast()
        }
        guard let url = URL(string: base + path), url.scheme == "https" || url.scheme == "http", url.host() != nil else {
            throw .invalidURL
        }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    static func send(_ request: URLRequest, session: URLSession) async throws(ClientServerError) -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw .transport
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw .server(status: -1)
        }
        switch httpResponse.statusCode {
        case 200..<300:
            return data
        case 401:
            throw .unauthorized
        default:
            throw .server(status: httpResponse.statusCode)
        }
    }

    static func pathComponent(_ value: String) throws(ClientServerError) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        guard let escaped = value.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw .invalidURL
        }
        return escaped
    }
}
