//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct ChatArtworkView: View {
    let artwork: ChatArtwork
    /// Set where the artwork tilts, which draws the still larger than the view so a tilt never shows its edges.
    var parallax: WallpaperParallax?
    
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    
    /// The last image, shown instead of the fallback while another size or appearance loads.
    @State private var loadedImage: UIImage?
    
    var body: some View {
        if let parallax {
            GeometryReader { geometry in
                let layout = WallpaperStillLayout(viewSize: geometry.size)
                let canvas = layout.canvasRect(at: .zero)
                
                still(canvasSize: canvas.size)
                    .frame(width: canvas.width, height: canvas.height)
                    .modifier(WallpaperParallaxOffset(parallax: parallax, layout: layout))
            }
            .clipped()
        } else {
            GeometryReader { geometry in
                still(canvasSize: geometry.size)
            }
        }
    }
    
    private func still(canvasSize: CGSize) -> some View {
        let request = ChatArtworkLoader.request(for: artwork, colorScheme: colorScheme, filling: canvasSize, displayScale: displayScale)
        let image = ChatArtworkLoader.cachedImage(for: request) ?? loadedImage
        let fallback = artwork.fallbackPreset.fill(for: colorScheme)
        
        // One canvas, so the grain blends once instead of on every scrolled frame.
        return Canvas { context, size in
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

/// Only this modifier reads the tilt, so a tilt moves the canvas without redrawing it.
private struct WallpaperParallaxOffset: ViewModifier {
    let parallax: WallpaperParallax
    let layout: WallpaperStillLayout
    
    func body(content: Content) -> some View {
        let canvas = layout.canvasRect(at: parallax.tilt)
        content.offset(x: canvas.minX, y: canvas.minY)
    }
}

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
    /// Faint grain, about one or two levels, that breaks up banding in smooth fills.
    func drawChatBackgroundGrain(size: CGSize) {
        guard let tile = ChatArtworkLoader.grainTile else { return }
        var context = self
        context.blendMode = .softLight
        context.opacity = 0.08
        // One grain pixel per screen pixel, whatever the scale.
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .tiledImage(Image(decorative: tile, scale: environment.displayScale)))
    }
}
