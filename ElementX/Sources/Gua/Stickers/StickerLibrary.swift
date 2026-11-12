//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

nonisolated enum StickerLibraryError: Error, Equatable {
    case limitReached
}

nonisolated struct StickerLibrary: Hashable, Sendable {
    static let accountDataType = "global.gua.stickers"
    static let maxFavourites = 50
    static let maxImages = 120
    
    private(set) var favourites: [StickerImage]
    /// My stickers, newest first by `global.gua.added`, then by shortcode.
    private(set) var images: [StickerPackItem]
    private(set) var version: Int64
    private var otherFields: [String: JSONValue]
    private var writesFavourites: Bool
    private var writesImages: Bool
    
    var contentJSON: String {
        var fields = otherFields
        fields["v"] = .int(version)
        if writesFavourites || !favourites.isEmpty {
            fields["favourites"] = .array(favourites.map(\.json))
        }
        if writesImages || !images.isEmpty {
            fields["images"] = .object(Dictionary(uniqueKeysWithValues: images.map { ($0.shortcode, $0.image.json) }))
        }
        return JSONValue.object(fields).jsonString
    }
    
    init(contentJSON: String?) {
        let fields = JSONValue(jsonString: contentJSON)?.objectValue ?? [:]
        let favourites = fields["favourites"]?.arrayValue
        let images = fields["images"]?.objectValue
        
        self.favourites = (favourites ?? []).compactMap(StickerImage.init(json:))
        self.images = Self.sorted((images ?? [:]).compactMap { shortcode, json in
            StickerImage(json: json).map { StickerPackItem(shortcode: shortcode, image: $0) }
        })
        version = fields["v"]?.intValue ?? 1
        otherFields = fields.filter { !["favourites", "images", "v"].contains($0.key) }
        writesFavourites = favourites != nil
        writesImages = images != nil
    }
    
    func isFavourite(url: String) -> Bool {
        favourites.contains { $0.url == url }
    }
    
    @discardableResult
    mutating func add(_ image: StickerImage, now: Int64) throws(StickerLibraryError) -> StickerPackItem {
        guard images.count < Self.maxImages else { throw .limitReached }
        
        let item = StickerPackItem(shortcode: Self.shortcode(now: now, existing: Set(images.map(\.shortcode))),
                                   image: image.essentials.with(added: now))
        images = Self.sorted(images + [item])
        return item
    }
    
    mutating func favourite(_ image: StickerImage) {
        let favourite = image.essentials
        favourites = Array(([favourite] + favourites.filter { $0.url != favourite.url }).prefix(Self.maxFavourites))
    }
    
    mutating func unfavourite(url: String) {
        favourites.removeAll { $0.url == url }
    }
    
    mutating func delete(shortcode: String) {
        guard let index = images.firstIndex(where: { $0.shortcode == shortcode }) else { return }
        unfavourite(url: images.remove(at: index).image.url)
    }
    
    /// `s` and the time in base 36, then `-2`, `-3` on collision.
    static func shortcode(now: Int64, existing: Set<String>) -> String {
        let base = "s" + String(max(now, 0), radix: 36)
        guard existing.contains(base) else { return base }
        
        var suffix = 2
        while existing.contains("\(base)-\(suffix)") {
            suffix += 1
        }
        return "\(base)-\(suffix)"
    }
    
    private static func sorted(_ items: [StickerPackItem]) -> [StickerPackItem] {
        items.sorted { lhs, rhs in
            switch (lhs.image.added, rhs.image.added) {
            case let (lhsAdded?, rhsAdded?) where lhsAdded != rhsAdded:
                lhsAdded > rhsAdded
            case (.some, .none):
                true
            case (.none, .some):
                false
            default:
                lhs.shortcode < rhs.shortcode
            }
        }
    }
}
