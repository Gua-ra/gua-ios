//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum RoomStateReadResult {
    /// The timestamp is 0 when the server returned the content without the event.
    case found(ChatBackgroundStoredValue)
    case notFound
    case failed(ClientServerError)
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
    
    init(session: URLSession = .shared, homeserver: @escaping () -> String, accessToken: @escaping () -> String?) {
        self.session = session
        self.homeserver = homeserver
        self.accessToken = accessToken
    }
    
    func chatBackground(roomID: String) async -> RoomStateReadResult {
        do throws(ClientServerError) {
            let data = try await read(roomID: roomID)
            return try .found(Self.storedValue(from: data))
        } catch .server(status: 404) {
            return .notFound
        } catch {
            MXLog.warning("Failed reading the chat background of \(roomID): \(error)")
            return .failed(error)
        }
    }
    
    static func path(roomID: String) throws(ClientServerError) -> String {
        try "/_matrix/client/v3/rooms/\(ClientServerHTTP.pathComponent(roomID))/state/\(ChatBackground.eventType)/"
    }
    
    private func read(roomID: String) async throws(ClientServerError) -> Data {
        guard let accessToken = accessToken() else {
            throw .missingAccessToken
        }
        let request = try ClientServerHTTP.makeRequest(homeserver: homeserver(),
                                                       path: Self.path(roomID: roomID) + "?format=event",
                                                       method: "GET",
                                                       accessToken: accessToken)
        return try await ClientServerHTTP.send(request, session: session)
    }
    
    private static func storedValue(from data: Data) throws(ClientServerError) -> ChatBackgroundStoredValue {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw .decoding(error)
        }
        guard let json = object as? [String: Any], let value = storedValue(from: json) else {
            throw .decoding(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Not a JSON object")))
        }
        return value
    }
    
    private static func storedValue(from json: [String: Any]) -> ChatBackgroundStoredValue? {
        guard let content = json["content"] as? [String: Any], json["type"] is String else {
            return ChatBackground.sortedJSON(json).map { ChatBackgroundStoredValue(contentJSON: $0, eventID: nil, timestamp: 0) }
        }
        let timestamp = (json["origin_server_ts"] as? NSNumber).map(\.uint64Value) ?? 0
        return ChatBackground.sortedJSON(content).map { ChatBackgroundStoredValue(contentJSON: $0, eventID: json["event_id"] as? String, timestamp: timestamp) }
    }
}
