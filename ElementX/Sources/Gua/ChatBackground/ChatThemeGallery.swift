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
        case colours
        case gradients
    }

    let id: Kind
    let themes: [ChatTheme]

    var title: String {
        switch id {
        case .featured: UntranslatedL10n.guaChatThemeSectionFeatured
        case .colours: UntranslatedL10n.guaChatThemeSectionColours
        case .gradients: UntranslatedL10n.guaChatThemeSectionGradients
        }
    }

    static let all: [ChatThemeGallerySection] = [
        .init(id: .featured, themes: [theme(.aurora, .green),
                                      theme(.ocean, .teal),
                                      theme(.sunset, .pink),
                                      theme(.night, .purple),
                                      theme(.dawn, .blue),
                                      theme(.forest, .green),
                                      theme(.dusk, .orange),
                                      theme(.citrus, .yellow)]),
        .init(id: .colours, themes: [theme(.mint, .green),
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

    private static func theme(_ preset: ChatBackgroundPreset, _ bubble: ChatBubbleColor) -> ChatTheme {
        ChatTheme(wallpaper: .preset(preset), bubble: bubble)
    }
}
