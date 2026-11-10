//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct ChatBackgroundView: View {
    let background: ChatBackground
    let mediaProvider: MediaProviderProtocol?
    
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    var body: some View {
        ZStack {
            layer
                .id(background)
                .transition(.opacity)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: background)
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true)
    }
    
    private var layer: some View {
        ZStack {
            switch background {
            case .none:
                Color.compound.bgCanvasDefault
            case .preset(let preset):
                ChatBackgroundFillView(fill: preset.fill(for: colorScheme))
                ChatBackgroundScrim(photoDim: nil)
            case .photo(let photo):
                ChatBackgroundPhotoView(photo: photo, mediaProvider: mediaProvider)
            }
        }
    }
}

struct ChatBackgroundScrim: View {
    let photoDim: Double?
    
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    
    var body: some View {
        if colorScheme == .dark {
            if let photoDim {
                Color.black.opacity(colorSchemeContrast == .increased ? max(photoDim, 0.5) : photoDim)
            }
        } else if colorSchemeContrast == .increased {
            // Increase Contrast swaps in darker light bubbles, which this keeps apart from the background.
            Color.black.opacity(0.06)
        }
    }
}

struct ChatBackgroundFillView: View {
    let fill: ChatBackgroundFill
    
    var body: some View {
        Canvas { context, size in
            let rect = Path(CGRect(origin: .zero, size: size))
            
            switch fill {
            case .solid(let hex):
                context.fill(rect, with: .color(Color(chatBackgroundHex: hex)))
            case .linear(let start, let end, let stops):
                let gradient = Gradient(stops: stops.map { .init(color: Color(chatBackgroundHex: $0.color), location: $0.location) })
                context.fill(rect, with: .linearGradient(gradient,
                                                         startPoint: CGPoint(x: start.x * size.width, y: start.y * size.height),
                                                         endPoint: CGPoint(x: end.x * size.width, y: end.y * size.height)))
            case .radialGlows(let base, let glows):
                context.fill(rect, with: .color(Color(chatBackgroundHex: base)))
                let longestSide = max(size.width, size.height)
                for glow in glows {
                    let gradient = Gradient(colors: [Color(chatBackgroundHex: glow.color), Color(chatBackgroundHex: glow.color, opacity: 0)])
                    context.fill(rect, with: .radialGradient(gradient,
                                                             center: CGPoint(x: glow.center.x * size.width, y: glow.center.y * size.height),
                                                             startRadius: 0,
                                                             endRadius: glow.radius * longestSide))
                }
            }
        }
    }
}

/// Aspect fill: a photo overflowing its frame by `o` on an axis is offset by `-o × align`, as on Android.
struct ChatBackgroundPhotoLayout: View {
    let image: UIImage
    /// The shape to fill with, when the image is a stand-in of another shape.
    var contentSize: CGSize?
    let alignX: Double
    let alignY: Double
    
    static func scaledSize(of content: CGSize, filling frame: CGSize) -> CGSize {
        let scale = max(frame.width / max(content.width, 1), frame.height / max(content.height, 1))
        return CGSize(width: content.width * scale, height: content.height * scale)
    }
    
    var body: some View {
        GeometryReader { geometry in
            let frame = geometry.size
            let scaled = Self.scaledSize(of: contentSize ?? image.size, filling: frame)
            
            Image(uiImage: image)
                .resizable()
                .frame(width: scaled.width, height: scaled.height)
                .offset(x: -(scaled.width - frame.width) * alignX, y: -(scaled.height - frame.height) * alignY)
        }
        .clipped()
    }
}

private struct ChatBackgroundPhotoView: View {
    let photo: ChatBackground.Photo
    let mediaProvider: MediaProviderProtocol?
    
    @Environment(\.displayScale) private var displayScale
    
    @State private var loadedImage: UIImage?
    @State private var hasFailed = false
    
    var body: some View {
        GeometryReader { geometry in
            let maxPixelSize = Int((max(geometry.size.width, geometry.size.height) * displayScale).rounded(.up))
            let image = loadedImage ?? ChatBackgroundPhotoLoader.cachedImage(for: photo, maxPixelSize: maxPixelSize, mediaProvider: mediaProvider)
            
            ZStack {
                Color.compound.bgCanvasDefault
                
                if let image {
                    ChatBackgroundPhotoLayout(image: image, alignX: photo.alignX, alignY: photo.alignY)
                } else if !hasFailed, let placeholder = photo.blurhash.flatMap(ChatBackgroundPhotoLoader.placeholder) {
                    ChatBackgroundPhotoLayout(image: placeholder,
                                              contentSize: CGSize(width: photo.width, height: photo.height),
                                              alignX: photo.alignX,
                                              alignY: photo.alignY)
                }
                
                if image != nil || !hasFailed {
                    ChatBackgroundScrim(photoDim: photo.dim)
                }
            }
            .task(id: LoadRequest(url: photo.url, maxPixelSize: maxPixelSize)) {
                guard image == nil, maxPixelSize > 0 else { return }
                loadedImage = await ChatBackgroundPhotoLoader.loadImage(for: photo, maxPixelSize: maxPixelSize, mediaProvider: mediaProvider)
                hasFailed = loadedImage == nil
            }
        }
    }
    
    private struct LoadRequest: Equatable {
        let url: String
        let maxPixelSize: Int
    }
}

struct ChatBackgroundView_Previews: PreviewProvider, TestablePreview {
    static let mediaProvider = MediaProviderMock(.init())
    
    static var previews: some View {
        grid
            .previewLayout(.sizeThatFits)
            .previewDisplayName("Light")
        
        grid
            .environment(\.colorScheme, .dark)
            .preferredColorScheme(.dark)
            .previewLayout(.sizeThatFits)
            .previewDisplayName("Dark")
    }
    
    static var grid: some View {
        let backgrounds: [ChatBackground] = [.none] + ChatBackgroundPreset.allCases.map(ChatBackground.preset) + [photo(dim: 0), photo(dim: ChatBackground.Photo.maxDim)]
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(64), spacing: 4), count: 5), spacing: 4) {
            ForEach(backgrounds, id: \.self) { background in
                ChatBackgroundView(background: background, mediaProvider: mediaProvider)
                    .frame(width: 64, height: 128)
            }
        }
        .padding(4)
        .background(Color.compound.bgCanvasDefault)
    }
    
    static func photo(dim: Double) -> ChatBackground {
        var photo = ChatBackground.Photo.mock
        photo.dim = dim
        return .photo(photo)
    }
}
