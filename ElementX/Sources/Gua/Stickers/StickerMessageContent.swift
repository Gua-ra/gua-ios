//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

nonisolated enum StickerRelation: Hashable, Sendable {
    case reply(eventID: String)
    /// Replies to the thread's latest event as a fallback, as the composer does for text.
    case thread(rootEventID: String, latestEventID: String)
}

nonisolated struct StickerMessageContent: Hashable, Sendable {
    static let eventType = "m.sticker"
    static let defaultBody = "Sticker"
    
    let image: StickerImage
    let relation: StickerRelation?
    
    var json: JSONValue {
        var fields: [String: JSONValue] = ["body": .string(image.body ?? Self.defaultBody), "url": .string(image.url)]
        fields["info"] = image.info?.json ?? .object([:])
        
        switch relation {
        case .reply(let eventID):
            fields["m.relates_to"] = .object(["m.in_reply_to": .object(["event_id": .string(eventID)])])
        case .thread(let rootEventID, let latestEventID):
            fields["m.relates_to"] = .object(["event_id": .string(rootEventID),
                                              "is_falling_back": .bool(true),
                                              "m.in_reply_to": .object(["event_id": .string(latestEventID)]),
                                              "rel_type": .string("m.thread")])
        case .none:
            break
        }
        return .object(fields)
    }
}
