//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum ChatBackground: Hashable {
    case none
    case preset(ChatBackgroundPreset)
    case photo(Photo)

    struct Photo: Hashable {
        static let defaultDim = 0.35
        static let maxDim = 0.8
        static let defaultAlign = 0.5
        /// Room versions 6 and later refuse floats in events, so dim is stored in whole percent and align in thousandths.
        static let dimScale = 100.0
        static let alignScale = 1000.0
        /// The largest file a photo background may declare, and the most that is downloaded to show one.
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

    static func sortedJSON(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

extension ChatBackground {
    init(contentJSON: String?) {
        guard let data = contentJSON?.data(using: .utf8),
              let content = try? JSONDecoder().decode(Content.self, from: data) else {
            self = .none
            return
        }
        self = content.background
    }

    var contentJSON: String {
        let content: EncodedContent
        switch self {
        case .none:
            return Self.removedContent
        case .preset(let preset):
            content = EncodedContent(kind: "preset", preset: preset.rawValue, photo: nil)
        case .photo(let photo):
            content = EncodedContent(kind: "photo",
                                     preset: nil,
                                     photo: .init(url: photo.url,
                                                  mimetype: photo.mimetype,
                                                  w: photo.width,
                                                  h: photo.height,
                                                  size: photo.size,
                                                  blurhash: photo.blurhash,
                                                  dim: photo.dim.storedUnits(per: Photo.dimScale),
                                                  align: .init(x: photo.alignX.storedUnits(per: Photo.alignScale),
                                                               y: photo.alignY.storedUnits(per: Photo.alignScale))))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(content), let json = String(data: data, encoding: .utf8) else {
            return Self.removedContent
        }
        return json
    }
}

private struct Content: Decodable {
    let background: ChatBackground

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case kind
        case preset
        case photo
        case fallbackPreset = "fallback_preset"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try? container.decodeInteger(forKey: .version)
        let kind = try? container.decode(String.self, forKey: .kind)

        switch (version, kind) {
        case (1, "preset"):
            background = Self.preset(from: container, key: .preset)
        case (1, "photo"):
            background = (try? container.decode(ChatBackground.Photo.self, forKey: .photo)).map(ChatBackground.photo) ?? .none
        default:
            background = Self.preset(from: container, key: .fallbackPreset)
        }
    }

    private static func preset(from container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> ChatBackground {
        guard let id = try? container.decode(String.self, forKey: key),
              let preset = ChatBackgroundPreset(rawValue: id) else {
            return .none
        }
        return .preset(preset)
    }
}

extension ChatBackground.Photo: Decodable {
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

        let blurhash = try container.decodeIfPresentAndNotNull(String.self, forKey: .blurhash)
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
        (Double(storedValue) / dimScale).clamped(to: 0...maxDim)
    }

    private static func align(_ storedValue: Int) -> Double {
        (Double(storedValue) / alignScale).clamped(to: 0...1)
    }
}

private struct EncodedContent: Encodable {
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

    let v = 1
    let kind: String
    let preset: String?
    let photo: Photo?
}

private extension KeyedDecodingContainer {
    func containsValue(forKey key: Key) throws -> Bool {
        guard contains(key) else { return false }
        return try !decodeNil(forKey: key)
    }

    /// Absent and null are both no value, but a value of the wrong type is an error.
    func decodeIfPresentAndNotNull<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        guard try containsValue(forKey: key) else { return nil }
        return try decode(type, forKey: key)
    }

    /// 800.0 is the same JSON number as 800, and Android reads it as an integer too.
    func decodeInteger(forKey key: Key) throws -> Int {
        if let integer = try? decode(Int.self, forKey: key) {
            return integer
        }
        let number = try decode(Double.self, forKey: key)
        guard number.isFinite, number == number.rounded(), let integer = Int(exactly: number) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Not a whole number")
        }
        return integer
    }

    func decodeIntegerIfPresentAndNotNull(forKey key: Key) throws -> Int? {
        guard try containsValue(forKey: key) else { return nil }
        return try decodeInteger(forKey: key)
    }
}

private extension Double {
    func storedUnits(per scale: Double) -> Int {
        Int((self * scale).rounded())
    }
}

struct ChatBackgroundTimelineEvent: Equatable {
    let eventID: String
    /// The server timestamp in milliseconds.
    let timestamp: UInt64
    /// Nil when the event's JSON cannot be read, which still reads as a change.
    let contentJSON: String?

    var isRemoval: Bool {
        contentJSON == ChatBackground.removedContent
    }
}

extension ChatBackgroundTimelineEvent {
    init(eventID: String, timestamp: UInt64, eventJSON: String?) {
        let content = eventJSON
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0["content"] as? [String: Any] }
        self.init(eventID: eventID, timestamp: timestamp, contentJSON: content.flatMap(ChatBackground.sortedJSON))
    }
}
