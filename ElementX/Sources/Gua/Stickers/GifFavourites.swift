//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// The `global.gua.gifs` account data. Only provider item ids are stored, never URLs or search terms.
nonisolated struct GifFavourites: Hashable, Sendable {
    static let accountDataType = "global.gua.gifs"
    static let maxFavourites = 50
    
    nonisolated struct Favourite: Hashable, Sendable {
        let id: String
        let provider: String
        fileprivate let fields: [String: JSONValue]
        
        init(id: String, provider: String) {
            self.id = id
            self.provider = provider
            fields = ["id": .string(id), "p": .string(provider)]
        }
        
        fileprivate init?(json: JSONValue) {
            guard let fields = json.objectValue, let id = fields["id"]?.stringValue, let provider = fields["p"]?.stringValue else {
                return nil
            }
            self.id = id
            self.provider = provider
            self.fields = fields
        }
    }
    
    /// Newest first.
    private(set) var favourites: [Favourite]
    private var version: Int64
    private var otherFields: [String: JSONValue]
    private var writesFavourites: Bool
    
    var contentJSON: String {
        var fields = otherFields
        fields["v"] = .int(version)
        if writesFavourites || !favourites.isEmpty {
            fields["favourites"] = .array(favourites.map { .object($0.fields) })
        }
        return JSONValue.object(fields).jsonString
    }
    
    init(contentJSON: String?) {
        let fields = JSONValue(jsonString: contentJSON)?.objectValue ?? [:]
        let favourites = fields["favourites"]?.arrayValue
        self.favourites = (favourites ?? []).compactMap(Favourite.init(json:))
        version = fields["v"]?.intValue ?? 1
        otherFields = fields.filter { !["favourites", "v"].contains($0.key) }
        writesFavourites = favourites != nil
    }
    
    func ids(provider: String) -> [String] {
        favourites.filter { $0.provider == provider }.map(\.id)
    }
    
    func contains(id: String, provider: String) -> Bool {
        favourites.contains { $0.id == id && $0.provider == provider }
    }
    
    mutating func favourite(id: String, provider: String, limit: Int = maxFavourites) {
        let favourite = Favourite(id: id, provider: provider)
        favourites = Array(([favourite] + favourites.filter { $0.id != id || $0.provider != provider }).prefix(limit))
    }
    
    mutating func unfavourite(id: String, provider: String) {
        favourites.removeAll { $0.id == id && $0.provider == provider }
    }
}
