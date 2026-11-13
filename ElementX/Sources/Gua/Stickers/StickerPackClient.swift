//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

nonisolated struct StickerPackStateEvent: Hashable, Sendable {
    let eventType: String
    let stateKey: String
    let content: JSONValue
}

// sourcery: AutoMockable
protocol StickerPackClientProtocol {
    func packEvents(roomID: String) async -> Result<[StickerPackStateEvent], ClientServerError>
}

/// Reads a chat's pack state events from the server, since the SDK only stores the state types the sync asks for
/// and has no way to list a type's state keys.
final class StickerPackClient: StickerPackClientProtocol {
    private let session: URLSession
    private let homeserver: () -> String
    private let accessToken: () -> String?
    
    init(session: URLSession = .shared, homeserver: @escaping () -> String, accessToken: @escaping () -> String?) {
        self.session = session
        self.homeserver = homeserver
        self.accessToken = accessToken
    }
    
    func packEvents(roomID: String) async -> Result<[StickerPackStateEvent], ClientServerError> {
        do throws(ClientServerError) {
            guard let accessToken = accessToken() else { throw .missingAccessToken }
            let request = try ClientServerHTTP.makeRequest(homeserver: homeserver(),
                                                           path: "/_matrix/client/v3/rooms/\(ClientServerHTTP.pathComponent(roomID))/state",
                                                           method: "GET",
                                                           accessToken: accessToken)
            let data = try await ClientServerHTTP.send(request, session: session)
            return try .success(Self.packEvents(from: data))
        } catch {
            MXLog.warning("Failed reading the sticker packs of \(roomID): \(error)")
            return .failure(error)
        }
    }
    
    static func packEvents(from data: Data) throws(ClientServerError) -> [StickerPackStateEvent] {
        let events: [JSONValue]
        do {
            events = try JSONDecoder().decode([JSONValue].self, from: data)
        } catch {
            throw .decoding(error)
        }
        return events.compactMap { event in
            guard let fields = event.objectValue,
                  let eventType = fields["type"]?.stringValue, StickerPack.eventTypes.contains(eventType),
                  let stateKey = fields["state_key"]?.stringValue,
                  let content = fields["content"], content.objectValue?.isEmpty == false else {
                return nil
            }
            return StickerPackStateEvent(eventType: eventType, stateKey: stateKey, content: content)
        }
    }
}
