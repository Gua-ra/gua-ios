//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Foundation

struct ChatThemeGallerySection: Identifiable {
    enum Kind {
        case featured
        case live
        case nature
        case photos
        case patterns
        case minimal
        case gradients
    }
    
    let id: Kind
    let themes: [ChatTheme]
    
    var title: String {
        id.title
    }
    
    static let all: [ChatThemeGallerySection] = [
        .init(id: .featured, themes: [ChatArtwork.silk, .glacierLake, .glassDrops, .currents, .palmCoast, .ipe, .azulejo, .paper].map(theme)),
        .init(id: .live, themes: ChatArtwork.artworks(in: .live).map(theme)),
        .init(id: .nature, themes: ChatArtwork.artworks(in: .nature).map(theme)),
        .init(id: .photos, themes: ChatArtwork.artworks(in: .photos).map(theme)),
        .init(id: .patterns, themes: ChatArtwork.artworks(in: .patterns).map(theme)),
        .init(id: .minimal, themes: ChatArtwork.artworks(in: .minimal).map(theme) + [theme(.mint, .green),
                                                                                     theme(.sky, .blue),
                                                                                     theme(.sand, .orange),
                                                                                     theme(.blush, .pink),
                                                                                     theme(.lavender, .purple),
                                                                                     theme(.graphite, .graphite)]),
        .init(id: .gradients, themes: [theme(.aurora, .teal),
                                       theme(.sunset, .orange),
                                       theme(.ocean, .blue),
                                       theme(.night, .purple),
                                       theme(.dawn, .pink),
                                       theme(.forest, .teal),
                                       theme(.dusk, .purple),
                                       theme(.citrus, .green)])
    ]
    
    private nonisolated static func theme(_ artwork: ChatArtwork) -> ChatTheme {
        ChatTheme(wallpaper: .art(artwork), bubbles: artwork.bubbles)
    }
    
    private nonisolated static func theme(_ preset: ChatBackgroundPreset, _ bubble: ChatBubbleColor) -> ChatTheme {
        ChatTheme(wallpaper: .preset(preset), bubble: bubble)
    }
}

struct ChatWallpaperGallerySection: Identifiable {
    let id: ChatThemeGallerySection.Kind
    let wallpapers: [ChatBackground]
    
    var title: String {
        id.title
    }
    
    static let all: [ChatWallpaperGallerySection] = [
        .init(id: .live, wallpapers: ChatArtwork.artworks(in: .live).map(ChatBackground.art)),
        .init(id: .nature, wallpapers: ChatArtwork.artworks(in: .nature).map(ChatBackground.art)),
        .init(id: .photos, wallpapers: ChatArtwork.artworks(in: .photos).map(ChatBackground.art)),
        .init(id: .patterns, wallpapers: ChatArtwork.artworks(in: .patterns).map(ChatBackground.art)),
        .init(id: .minimal, wallpapers: ChatArtwork.artworks(in: .minimal).map(ChatBackground.art) + ChatBackgroundPreset.solids.map(ChatBackground.preset)),
        .init(id: .gradients, wallpapers: ChatBackgroundPreset.gradients.map(ChatBackground.preset))
    ]
}

extension ChatThemeGallerySection.Kind {
    var title: String {
        switch self {
        case .featured: UntranslatedL10n.guaChatThemeSectionFeatured
        case .live: UntranslatedL10n.guaChatThemeSectionLive
        case .nature: UntranslatedL10n.guaChatThemeSectionNature
        case .photos: UntranslatedL10n.guaChatThemeSectionPhotos
        case .patterns: UntranslatedL10n.guaChatThemeSectionPatterns
        case .minimal: UntranslatedL10n.guaChatThemeSectionMinimal
        case .gradients: UntranslatedL10n.guaChatThemeSectionGradients
        }
    }
}
