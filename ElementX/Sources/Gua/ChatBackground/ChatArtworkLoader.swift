//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import ImageIO
import SwiftUI

enum ChatArtworkLoader {
    nonisolated struct Request: Hashable {
        let file: String
        let maxPixelSize: Int
        
        fileprivate var cacheKey: NSString {
            "\(file){\(maxPixelSize)}" as NSString
        }
    }
    
    /// Decoded sizes are rounded up to this step, so a frame that changes a little reuses its image.
    private static let pixelStep = 256.0
    private static let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()
    
    /// The grain drawn over artworks and gradients, a small tile that is decoded once.
    static let grainTile: CGImage? = url(for: "noise.webp")
        .flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }
        .flatMap { CGImageSourceCreateImageAtIndex($0, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) }
    
    static func request(for artwork: ChatArtwork, colorScheme: ColorScheme, filling frame: CGSize, displayScale: CGFloat) -> Request {
        let scaled = ChatBackgroundPhotoLayout.scaledSize(of: ChatArtwork.pixelSize, filling: frame)
        let pixels = max(scaled.width, scaled.height) * displayScale
        let fullSize = Int(max(ChatArtwork.pixelSize.width, ChatArtwork.pixelSize.height))
        let maxPixelSize = min(Int((pixels / pixelStep).rounded(.up) * pixelStep), fullSize)
        return Request(file: artwork.fileName(for: colorScheme), maxPixelSize: maxPixelSize)
    }
    
    static func cachedImage(for request: Request) -> UIImage? {
        if let image = images.object(forKey: request.cacheKey) {
            return image
        }
        // Snapshots are drawn once and never wait for a load.
        guard ProcessInfo.isRunningTests, let image = decodeImage(for: request) else { return nil }
        store(image, for: request)
        return image
    }
    
    static func loadImage(for request: Request) async -> UIImage? {
        if let image = images.object(forKey: request.cacheKey) {
            return image
        }
        
        let image = await Task.detached(priority: .userInitiated) {
            decodeImage(for: request)
        }.value
        
        if let image {
            store(image, for: request)
        }
        return image
    }
    
    nonisolated static func url(for file: String) -> URL? {
        Bundle.main.url(forResource: file, withExtension: nil, subdirectory: ChatArtwork.folder)
    }
    
    private static func store(_ image: UIImage, for request: Request) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        images.setObject(image, forKey: request.cacheKey, cost: cost)
    }
    
    private nonisolated static func decodeImage(for request: Request) -> UIImage? {
        guard request.maxPixelSize > 0,
              let url = url(for: request.file),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = ChatBackgroundImageProcessor.uprightImage(from: source, maxPixelSize: request.maxPixelSize) else {
            MXLog.error("Failed decoding the chat wallpaper \(request.file)")
            return nil
        }
        return UIImage(cgImage: image)
    }
}
