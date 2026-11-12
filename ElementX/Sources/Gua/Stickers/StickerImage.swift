//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// An image pack image object, `{"body":..,"info":{..},"url":"mxc://.."}`, keeping every field it was read with.
nonisolated struct StickerImage: Hashable, Sendable {
    static let addedKey = "global.gua.added"
    static let maxDisplaySide = 256
    
    let url: String
    private(set) var fields: [String: JSONValue]
    
    var body: String? {
        fields["body"]?.stringValue
    }
    
    var info: StickerImageInfo? {
        fields["info"]?.objectValue.map(StickerImageInfo.init(fields:))
    }
    
    /// When the user added it to My stickers, in milliseconds.
    var added: Int64? {
        fields[Self.addedKey]?.intValue
    }
    
    var isAnimated: Bool {
        info?.isAnimated == true || info?.mimetype == "image/gif"
    }
    
    var json: JSONValue {
        .object(fields)
    }
    
    /// Only the fields a favourite or a message carries.
    var essentials: StickerImage {
        var image = self
        image.fields = fields.filter { ["body", "info", "url"].contains($0.key) }
        return image
    }
    
    init?(json: JSONValue) {
        guard let fields = json.objectValue, let url = fields["url"]?.stringValue, url.hasPrefix("mxc://") else {
            return nil
        }
        self.url = url
        self.fields = fields
    }
    
    init(url: String, body: String?, info: StickerImageInfo?) {
        self.url = url
        var fields: [String: JSONValue] = ["url": .string(url)]
        fields["body"] = body.map(JSONValue.string)
        fields["info"] = info?.json
        self.fields = fields
    }
    
    /// A freshly uploaded file, whose display size is half its pixel size, at most 256.
    init(url: String, body: String?, mimetype: String, pixelWidth: Int, pixelHeight: Int, size: Int, isAnimated: Bool) {
        let displaySize = Self.displaySize(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        self.init(url: url,
                  body: body,
                  info: StickerImageInfo(width: displaySize.width,
                                         height: displaySize.height,
                                         mimetype: mimetype,
                                         size: size,
                                         isAnimated: isAnimated ? true : nil))
    }
    
    static func displaySize(pixelWidth: Int, pixelHeight: Int) -> (width: Int, height: Int) {
        let longestSide = Double(max(pixelWidth, pixelHeight, 1))
        let scale = min(0.5, Double(maxDisplaySide) / longestSide)
        return (max(1, Int((Double(pixelWidth) * scale).rounded())), max(1, Int((Double(pixelHeight) * scale).rounded())))
    }
    
    func with(body: String) -> StickerImage {
        var image = self
        image.fields["body"] = .string(body)
        return image
    }
    
    func with(added: Int64) -> StickerImage {
        var image = self
        image.fields[Self.addedKey] = .int(added)
        return image
    }
}

nonisolated extension StickerImage: Codable {
    init(from decoder: Decoder) throws {
        guard let image = try StickerImage(json: JSONValue(from: decoder)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a sticker image"))
        }
        self = image
    }
    
    func encode(to encoder: Encoder) throws {
        try json.encode(to: encoder)
    }
}

/// The `info` of an image, keeping every field it was read with.
nonisolated struct StickerImageInfo: Hashable, Sendable {
    private(set) var fields: [String: JSONValue]
    
    var width: Int? {
        fields["w"]?.intValue.map(Int.init)
    }
    
    var height: Int? {
        fields["h"]?.intValue.map(Int.init)
    }
    
    var mimetype: String? {
        fields["mimetype"]?.stringValue
    }
    
    var size: Int? {
        fields["size"]?.intValue.map(Int.init)
    }
    
    var isAnimated: Bool? {
        fields["is_animated"]?.boolValue
    }
    
    var json: JSONValue {
        .object(fields)
    }
    
    init(fields: [String: JSONValue]) {
        self.fields = fields
    }
    
    init(width: Int?, height: Int?, mimetype: String?, size: Int?, isAnimated: Bool? = nil) {
        var fields: [String: JSONValue] = [:]
        fields["w"] = width.map { .int(Int64($0)) }
        fields["h"] = height.map { .int(Int64($0)) }
        fields["mimetype"] = mimetype.map(JSONValue.string)
        fields["size"] = size.map { .int(Int64($0)) }
        fields["is_animated"] = isAnimated.map(JSONValue.bool)
        self.fields = fields
    }
}

/// An image of a pack's `images` map, under its shortcode.
nonisolated struct StickerPackItem: Hashable, Sendable, Identifiable {
    let shortcode: String
    let image: StickerImage
    
    var id: String {
        shortcode
    }
}
