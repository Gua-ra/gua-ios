//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Compound
import Kingfisher
import SwiftUI

/// A provider's animated image, fetched through the provider so it takes the proxy and never the app's media pipeline.
struct GifImage: View {
    @Environment(\.accessibilityPlayAnimatedImages) private var playAnimatedImages
    @Environment(\.gifPreviewImages) private var previewImages
    
    let file: GifFile
    let provider: GifProvider
    
    var body: some View {
        Group {
            if let previewImage = previewImages[file.url] {
                Image(uiImage: previewImage)
                    .resizable()
            } else {
                KFAnimatedImage(source: .provider(GifDataProvider(url: file.url, provider: provider)))
                    .setProcessor(AnimatedImageProcessor())
                    .cacheMemoryOnly()
                    .configure { view in
                        view.autoPlayAnimatedImage = playAnimatedImages
                    }
                    .placeholder { Color.compound.bgSubtleSecondary }
            }
        }
        .aspectRatio(CGFloat(max(file.width, 1)) / CGFloat(max(file.height, 1)), contentMode: .fit)
    }
}

extension EnvironmentValues {
    /// Previews draw these at once, since Kingfisher only starts loading after a view appears and snapshots don't wait.
    @Entry var gifPreviewImages: [URL: UIImage] = [:]
}

private nonisolated struct GifDataProvider: ImageDataProvider {
    let url: URL
    let provider: GifProvider
    
    var cacheKey: String {
        url.absoluteString
    }
    
    func data(handler: @escaping @Sendable (Result<Data, Error>) -> Void) {
        Task {
            await handler(provider.data(from: url).mapError { $0 as Error })
        }
    }
}
