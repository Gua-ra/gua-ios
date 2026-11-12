//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

nonisolated struct GifFile: Hashable, Sendable {
    let url: URL
    let width: Int
    let height: Int
    let size: Int
}

nonisolated struct GifRendition: Hashable, Sendable {
    enum Name: String, CaseIterable, Sendable {
        case hd, md, sm, xs
    }
    
    let name: Name
    /// Animated WebP.
    let animated: GifFile
    /// A JPEG of the first frame, at the same size.
    let still: GifFile?
}

/// What a GIF is sent as: the `hd` rendition up to 1.5 MB, otherwise the next one down.
nonisolated struct GifSendChoice: Hashable, Sendable {
    static let maxSendSize = 1_500_000
    static let defaultBody = "GIF"
    
    let body: String
    let rendition: GifRendition.Name
    let animated: GifFile
    let still: GifFile
}

nonisolated struct GifItem: Hashable, Sendable, Identifiable {
    /// The id the provider looks the item up by again.
    let id: String
    let title: String
    let renditions: [GifRendition.Name: GifRendition]
    
    /// The smallest rendition, for a grid.
    var preview: GifRendition? {
        [.sm, .xs, .md, .hd].lazy.compactMap { renditions[$0] }.first
    }
    
    var sendChoice: GifSendChoice? {
        let candidates = GifRendition.Name.allCases.compactMap { renditions[$0] }.filter { $0.still != nil }
        let rendition = candidates.first { $0.name != .hd || $0.animated.size <= GifSendChoice.maxSendSize } ?? candidates.first
        guard let rendition, let still = rendition.still else { return nil }
        
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return GifSendChoice(body: title.isEmpty ? GifSendChoice.defaultBody : title,
                             rendition: rendition.name,
                             animated: rendition.animated,
                             still: still)
    }
}

nonisolated struct GifPage: Hashable, Sendable {
    /// In the order the provider returned them, which is never changed.
    let items: [GifItem]
    let page: Int
    let hasNext: Bool
}

nonisolated enum GifProviderError: Error {
    case unavailable
    case cancelled
    case disallowedURL
    case network(URLError)
    case server(status: Int)
    case decoding
}

// sourcery: AutoMockable
nonisolated protocol GifProvider: Sendable {
    /// The `p` written next to each favourite's id.
    var id: String { get }
    /// False without an API key, in which case every request fails.
    var isAvailable: Bool { get }
    
    /// Pages start at 1. Cancelling the calling task cancels the request.
    func search(_ query: String, page: Int) async -> Result<GifPage, GifProviderError>
    func trending(page: Int) async -> Result<GifPage, GifProviderError>
    func items(ids: [String]) async -> Result<[GifItem], GifProviderError>
    /// Media from the provider's hosts, through the same session and proxy.
    func data(from url: URL) async -> Result<Data, GifProviderError>
}
