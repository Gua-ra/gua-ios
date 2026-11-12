//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

nonisolated struct StickerPack: Hashable, Sendable, Identifiable {
    static let stableEventType = "m.room.image_pack"
    static let unstableEventType = "im.ponies.room_emotes"
    static let eventTypes = [stableEventType, unstableEventType]
    
    let eventType: String
    let stateKey: String
    let displayName: String
    let avatarURL: String?
    let stickers: [StickerPackItem]
    
    var id: String {
        "\(eventType)|\(stateKey)"
    }
    
    init(eventType: String, stateKey: String, content: JSONValue, roomName: String, roomAvatarURL: String?) {
        let fields = content.objectValue ?? [:]
        let pack = fields["pack"]?.objectValue ?? [:]
        let packIsSticker = Self.includesStickers(pack["usage"])
        let readsImageUsage = eventType == Self.unstableEventType
        
        self.eventType = eventType
        self.stateKey = stateKey
        displayName = pack["display_name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? roomName
        avatarURL = pack["avatar_url"]?.stringValue ?? roomAvatarURL
        stickers = (fields["images"]?.objectValue ?? [:])
            .compactMap { shortcode, json -> StickerPackItem? in
                guard let image = StickerImage(json: json) else { return nil }
                let usage = readsImageUsage ? json.objectValue?["usage"] : nil
                let isSticker = Self.hasUsage(usage) ? Self.includesStickers(usage) : packIsSticker
                guard isSticker else { return nil }
                return StickerPackItem(shortcode: shortcode, image: image.body?.isEmpty == false ? image : image.with(body: shortcode))
            }
            .sorted { $0.shortcode < $1.shortcode }
    }
    
    private static func hasUsage(_ usage: JSONValue?) -> Bool {
        usage?.arrayValue?.isEmpty == false
    }
    
    private static func includesStickers(_ usage: JSONValue?) -> Bool {
        guard hasUsage(usage), let usage = usage?.arrayValue else { return true }
        return usage.contains(.string("sticker"))
    }
}
