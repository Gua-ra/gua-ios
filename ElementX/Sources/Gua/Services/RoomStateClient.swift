//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum RoomStateClientError: Error, Equatable {
    case invalidURL
    case missingAccessToken
    /// The SDK refreshes the token on its own, so a 401 only skips this attempt and never signs out.
    case unauthorized
    case server(status: Int)
    case transport
    case decoding
}

enum RoomStateReadResult: Equatable {
    /// The timestamp is 0 when the server returned the content without the event.
    case found(ChatBackgroundStoredValue)
    case notFound
    case failed(RoomStateClientError)
}

// sourcery: AutoMockable
protocol RoomStateClientProtocol {
    func chatBackground(roomID: String) async -> RoomStateReadResult
}

/// Reads a chat's background from the server, since the SDK can neither fetch nor reliably store this custom state.
final class RoomStateClient: RoomStateClientProtocol {
    private let session: URLSession
    private let homeserver: () -> String
    private let accessToken: () -> String?
    private let timeout: TimeInterval = 15

    init(session: URLSession = .shared, homeserver: @escaping () -> String, accessToken: @escaping () -> String?) {
        self.session = session
        self.homeserver = homeserver
        self.accessToken = accessToken
    }

    func chatBackground(roomID: String) async -> RoomStateReadResult {
        let data: Data
        do {
            let request = try makeRequest(roomID: roomID)
            data = try await send(request)
        } catch RoomStateClientError.server(status: 404) {
            return .notFound
        } catch let error as RoomStateClientError {
            MXLog.warning("Failed reading the chat background of \(roomID): \(error)")
            return .failed(error)
        } catch {
            return .failed(.transport)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failed(.decoding)
        }
        return .found(Self.storedValue(from: json))
    }

    static func path(roomID: String) throws -> String {
        try "/_matrix/client/v3/rooms/\(pathComponent(roomID))/state/\(ChatBackground.eventType)/"
    }

    private static func storedValue(from json: [String: Any]) -> ChatBackgroundStoredValue {
        if let content = json["content"] as? [String: Any], json["type"] is String {
            let timestamp = (json["origin_server_ts"] as? NSNumber).map(\.uint64Value) ?? 0
            return ChatBackgroundStoredValue(contentJSON: serialized(content), eventID: json["event_id"] as? String, timestamp: timestamp)
        } else {
            return ChatBackgroundStoredValue(contentJSON: serialized(json), eventID: nil, timestamp: 0)
        }
    }

    private static func serialized(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys),
              let json = String(data: data, encoding: .utf8) else {
            return ChatBackground.removedContent
        }
        return json
    }

    private func makeRequest(roomID: String) throws -> URLRequest {
        guard let accessToken = accessToken() else {
            throw RoomStateClientError.missingAccessToken
        }

        var base = homeserver()
        while base.hasSuffix("/") {
            base.removeLast()
        }
        guard var components = try URLComponents(string: base + Self.path(roomID: roomID)),
              components.scheme == "https" || components.scheme == "http", components.host != nil else {
            throw RoomStateClientError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "format", value: "event")]
        guard let url = components.url else {
            throw RoomStateClientError.invalidURL
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RoomStateClientError.transport
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RoomStateClientError.server(status: -1)
        }
        switch httpResponse.statusCode {
        case 200..<300:
            return data
        case 401:
            throw RoomStateClientError.unauthorized
        default:
            throw RoomStateClientError.server(status: httpResponse.statusCode)
        }
    }

    private static func pathComponent(_ value: String) throws -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        guard let escaped = value.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw RoomStateClientError.invalidURL
        }
        return escaped
    }
}
