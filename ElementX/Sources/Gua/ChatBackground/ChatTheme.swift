//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Foundation

nonisolated struct ChatTheme: Hashable {
    static let stock = ChatTheme(wallpaper: .none)
    
    var wallpaper: ChatBackground
    var bubbles: ChatBubblePair
    
    var bubble: ChatBubbleColor {
        bubbles.bubble
    }
    
    var bubbleDark: ChatBubbleColor? {
        bubbles.bubbleDark
    }
    
    var isStock: Bool {
        self == .stock
    }
    
    init(wallpaper: ChatBackground, bubbles: ChatBubblePair) {
        self.wallpaper = wallpaper
        self.bubbles = bubbles
    }
    
    init(wallpaper: ChatBackground, bubble: ChatBubbleColor = .standard, bubbleDark: ChatBubbleColor? = nil) {
        self.init(wallpaper: wallpaper, bubbles: ChatBubblePair(bubble, dark: bubbleDark))
    }
    
    /// When the media setting hides the chat's photo, the whole default theme shows instead. The default's own photo always shows.
    static func effective(chatTheme: ChatTheme, defaultTheme: ChatTheme, roomIsPrivate: Bool, mediaShown: Bool) -> ChatTheme {
        guard !chatTheme.isStock else { return defaultTheme }
        if chatTheme.wallpaper.photo != nil, !roomIsPrivate, !mediaShown {
            return defaultTheme
        }
        return chatTheme
    }
}

nonisolated enum ChatBackground: Hashable {
    case none
    case preset(ChatBackgroundPreset)
    case art(ChatArtwork)
    case photo(Photo)
    
    struct Photo: Hashable {
        static let defaultDim = 0.35
        static let maxDim = 0.8
        static let defaultAlign = 0.5
        /// Room versions 6 and later refuse floats in events, so dim is stored in whole percent and align in thousandths.
        static let dimScale = 100.0
        static let alignScale = 1000.0
        /// The largest photo file accepted as declared and decoded; the SDK downloads the whole file before it is checked.
        static let maxSize = 20_000_000
        
        var url: String
        var mimetype: String
        var width: Int
        var height: Int
        var size: Int
        var blurhash: String?
        var dim = defaultDim
        /// Where the photo sits when it overflows the frame: 0 pins its left or top edge, 1 its right or bottom edge.
        var alignX = defaultAlign
        var alignY = defaultAlign
    }
    
    static let eventType = "global.gua.room.background"
    static let removedContent = "{}"
    
    var isNone: Bool {
        self == .none
    }
    
    var photo: Photo? {
        guard case .photo(let photo) = self else { return nil }
        return photo
    }
    
    var artwork: ChatArtwork? {
        guard case .art(let artwork) = self else { return nil }
        return artwork
    }
    
    static func sortedJSON(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

nonisolated extension ChatTheme {
    init(contentJSON: String?) {
        guard let data = contentJSON?.data(using: .utf8),
              let content = try? JSONDecoder().decode(Content.self, from: data) else {
            self = .stock
            return
        }
        self = content.theme
    }
    
    var contentJSON: String {
        guard !isStock else { return ChatBackground.removedContent }
        
        let bubbleID = bubble == .standard ? nil : bubble.rawValue
        let bubbleDarkID = bubbleDark?.rawValue
        let content = switch wallpaper {
        case .none:
            EncodedContent(bubble: bubbleID, bubbleDark: bubbleDarkID, kind: "none")
        case .preset(let preset):
            EncodedContent(bubble: bubbleID, bubbleDark: bubbleDarkID, kind: "preset", preset: preset.rawValue)
        case .art(let artwork):
            EncodedContent(art: artwork.rawValue,
                           bubble: bubbleID,
                           bubbleDark: bubbleDarkID,
                           fallbackPreset: artwork.fallbackPreset.rawValue,
                           kind: "art")
        case .photo(let photo):
            EncodedContent(bubble: bubbleID,
                           bubbleDark: bubbleDarkID,
                           kind: "photo",
                           photo: .init(url: photo.url,
                                        mimetype: photo.mimetype,
                                        w: photo.width,
                                        h: photo.height,
                                        size: photo.size,
                                        blurhash: photo.blurhash,
                                        dim: photo.dim.storedUnits(per: ChatBackground.Photo.dimScale),
                                        align: .init(x: photo.alignX.storedUnits(per: ChatBackground.Photo.alignScale),
                                                     y: photo.alignY.storedUnits(per: ChatBackground.Photo.alignScale))))
        }
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(content), let json = String(data: data, encoding: .utf8) else {
            return ChatBackground.removedContent
        }
        return json
    }
}

private nonisolated struct Content: Decodable {
    let theme: ChatTheme
    
    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case kind
        case preset
        case art
        case photo
        case bubble
        case bubbleDark = "bubble_dark"
        case fallbackPreset = "fallback_preset"
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try? container.decodeInteger(forKey: .version)
        let kind = try? container.decode(String.self, forKey: .kind)
        
        let wallpaper: ChatBackground = switch (version, kind) {
        case (1, "preset"):
            Self.preset(from: container, key: .preset)
        case (1, "art"):
            (try? container.decode(String.self, forKey: .art)).flatMap(ChatArtwork.init(rawValue:)).map(ChatBackground.art)
                ?? Self.preset(from: container, key: .fallbackPreset)
        case (1, "photo"):
            (try? container.decode(ChatBackground.Photo.self, forKey: .photo)).map(ChatBackground.photo) ?? .none
        case (1, "none"):
            .none
        default:
            Self.preset(from: container, key: .fallbackPreset)
        }
        
        // Only v1 has bubbles. An unknown bubble reads as standard and keeps the wallpaper.
        let bubble = version == 1 ? Self.bubble(from: container, key: .bubble) : nil
        let bubbleDark = version == 1 ? Self.bubble(from: container, key: .bubbleDark) : nil
        theme = ChatTheme(wallpaper: wallpaper, bubble: bubble ?? .standard, bubbleDark: bubbleDark)
    }
    
    private static func bubble(from container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> ChatBubbleColor? {
        (try? container.decode(String.self, forKey: key)).flatMap(ChatBubbleColor.init(rawValue:))
    }
    
    private static func preset(from container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> ChatBackground {
        guard let id = try? container.decode(String.self, forKey: key),
              let preset = ChatBackgroundPreset(rawValue: id) else {
            return .none
        }
        return .preset(preset)
    }
}

nonisolated extension ChatBackground.Photo: Decodable {
    private enum CodingKeys: String, CodingKey {
        case url, mimetype, w, h, size, blurhash, dim, align
    }
    
    private enum AlignCodingKeys: String, CodingKey {
        case x, y
    }
    
    private struct InvalidContent: Error { }
    
    private static let maxDimension = 8192
    private static let maxBlurhashLength = 100
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        let url = try container.decode(String.self, forKey: .url)
        let mimetype = try container.decode(String.self, forKey: .mimetype)
        let width = try container.decodeInteger(forKey: .w)
        let height = try container.decodeInteger(forKey: .h)
        let size = try container.decodeInteger(forKey: .size)
        
        guard url.hasPrefix("mxc://"),
              mimetype.hasPrefix("image/"),
              (1...Self.maxDimension).contains(width),
              (1...Self.maxDimension).contains(height),
              (1...Self.maxSize).contains(size) else {
            throw InvalidContent()
        }
        
        let blurhash = try container.decodeIfPresent(String.self, forKey: .blurhash)
        if let blurhash, blurhash.utf16.count > Self.maxBlurhashLength {
            throw InvalidContent()
        }
        
        let dim = try container.decodeIntegerIfPresentAndNotNull(forKey: .dim)
        
        var alignX: Int?
        var alignY: Int?
        if try container.containsValue(forKey: .align) {
            let align = try container.nestedContainer(keyedBy: AlignCodingKeys.self, forKey: .align)
            alignX = try align.decodeIntegerIfPresentAndNotNull(forKey: .x)
            alignY = try align.decodeIntegerIfPresentAndNotNull(forKey: .y)
        }
        
        self.init(url: url,
                  mimetype: mimetype,
                  width: width,
                  height: height,
                  size: size,
                  blurhash: blurhash,
                  dim: dim.map(Self.dim) ?? Self.defaultDim,
                  alignX: alignX.map(Self.align) ?? Self.defaultAlign,
                  alignY: alignY.map(Self.align) ?? Self.defaultAlign)
    }
    
    private static func dim(_ storedValue: Int) -> Double {
        min(max(Double(storedValue) / dimScale, 0), maxDim)
    }
    
    private static func align(_ storedValue: Int) -> Double {
        min(max(Double(storedValue) / alignScale, 0), 1)
    }
}

private nonisolated struct EncodedContent: Encodable {
    struct Photo: Encodable {
        struct Align: Encodable {
            let x: Int
            let y: Int
        }
        
        let url: String
        let mimetype: String
        let w: Int
        let h: Int
        let size: Int
        let blurhash: String?
        let dim: Int
        let align: Align
    }
    
    private enum CodingKeys: String, CodingKey {
        case v
        case art
        case bubble
        case bubbleDark = "bubble_dark"
        case fallbackPreset = "fallback_preset"
        case kind
        case preset
        case photo
    }
    
    let v = 1
    var art: String?
    let bubble: String?
    let bubbleDark: String?
    var fallbackPreset: String?
    let kind: String
    var preset: String?
    var photo: Photo?
}

private nonisolated extension KeyedDecodingContainer {
    func containsValue(forKey key: Key) throws -> Bool {
        guard contains(key) else { return false }
        return try !decodeNil(forKey: key)
    }
    
    /// 800.0 is the same JSON number as 800, and Android reads it as an integer too.
    func decodeInteger(forKey key: Key) throws -> Int {
        if let integer = try? decode(Int.self, forKey: key) {
            return integer
        }
        let number = try decode(Double.self, forKey: key)
        guard let integer = Int(exactly: number) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Not a whole number")
        }
        return integer
    }
    
    func decodeIntegerIfPresentAndNotNull(forKey key: Key) throws -> Int? {
        guard try containsValue(forKey: key) else { return nil }
        return try decodeInteger(forKey: key)
    }
}

private nonisolated extension Double {
    func storedUnits(per scale: Double) -> Int {
        Int((self * scale).rounded())
    }
}

nonisolated struct ChatBackgroundTimelineEvent: Equatable {
    let eventID: String
    let timestamp: UInt64
    /// Nil when the event's JSON cannot be read, which still reads as a change.
    let contentJSON: String?
    
    var isRemoval: Bool {
        contentJSON == ChatBackground.removedContent
    }
}

nonisolated extension ChatBackgroundTimelineEvent {
    init(eventID: String, timestamp: UInt64, eventJSON: String?) {
        let content = eventJSON
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0["content"] as? [String: Any] }
        self.init(eventID: eventID, timestamp: timestamp, contentJSON: content.flatMap(ChatBackground.sortedJSON))
    }
}
