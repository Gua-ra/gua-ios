//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

/// An artwork's still for the current appearance, cropped around its anchor, over its fallback preset while it loads.
struct ChatArtworkView: View {
    let artwork: ChatArtwork
    
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    
    /// Still shown while another size or appearance loads, so a change never flashes the fallback.
    @State private var loadedImage: UIImage?
    
    var body: some View {
        GeometryReader { geometry in
            let request = ChatArtworkLoader.request(for: artwork, colorScheme: colorScheme, filling: geometry.size, displayScale: displayScale)
            let image = ChatArtworkLoader.cachedImage(for: request) ?? loadedImage
            let fallback = artwork.fallbackPreset.fill(for: colorScheme)
            
            // One canvas, so the grain is blended once rather than on every frame the chat scrolls.
            Canvas { context, size in
                context.drawChatBackgroundFill(fallback, size: size)
                if let image {
                    let rect = ChatBackgroundPhotoLayout.rect(of: ChatArtwork.pixelSize,
                                                              filling: size,
                                                              alignX: artwork.anchor.x,
                                                              alignY: artwork.anchor.y)
                    context.draw(Image(uiImage: image).interpolation(.high), in: rect)
                }
                context.drawChatBackgroundGrain(size: size)
            }
            .task(id: request) {
                guard request.maxPixelSize > 0, let image = await ChatArtworkLoader.loadImage(for: request) else { return }
                loadedImage = image
            }
        }
    }
}

/// Marks a tile whose artwork moves, while the tile itself shows a still.
struct ChatArtworkLiveBadge: View {
    var body: some View {
        Text(UntranslatedL10n.guaChatThemeLiveBadge)
            .font(.compound.bodyXSSemibold)
            .foregroundStyle(.compound.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .legibilityCapsule()
            .environment(\.chatBackgroundActive, true)
    }
}

extension GraphicsContext {
    /// A tiled grain at very low strength, about one or two levels, which breaks up the banding of smooth fills.
    func drawChatBackgroundGrain(size: CGSize) {
        guard let tile = ChatArtworkLoader.grainTile else { return }
        var context = self
        context.blendMode = .softLight
        context.opacity = 0.08
        // One grain pixel per screen pixel, whatever the scale.
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .tiledImage(Image(decorative: tile, scale: environment.displayScale)))
    }
}
