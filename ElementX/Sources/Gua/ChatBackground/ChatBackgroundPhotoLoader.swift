//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import ImageIO
import UIKit
import UniformTypeIdentifiers

@MainActor
enum ChatBackgroundPhotoLoader {
    private static let decodedImages = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    private static let placeholders = NSCache<NSString, UIImage>()
    private static let placeholderSize = 32
    /// Gua clients upload at most 2048 pixels on an edge, so anything far larger is refused before decoding.
    private nonisolated static let maxDecodedEdge = 4096
    private nonisolated static let decodableTypes: Set<String> = [UTType.jpeg.identifier, UTType.png.identifier, UTType.heic.identifier, UTType.webP.identifier]

    static func cachedImage(for photo: ChatBackground.Photo, maxPixelSize: Int, mediaProvider: MediaProviderProtocol?) -> UIImage? {
        if let image = decodedImages.object(forKey: cacheKey(photo, maxPixelSize)) {
            return image
        }
        return mediaSource(for: photo).flatMap { mediaProvider?.imageFromSource($0, size: nil) }
    }

    static func loadImage(for photo: ChatBackground.Photo, maxPixelSize: Int, mediaProvider: MediaProviderProtocol?) async -> UIImage? {
        if let image = cachedImage(for: photo, maxPixelSize: maxPixelSize, mediaProvider: mediaProvider) {
            return image
        }
        guard let mediaProvider, let source = mediaSource(for: photo),
              case .success(let file) = await mediaProvider.loadFileFromSource(source, filename: nil) else {
            return nil
        }

        let image = await Task.detached(priority: .userInitiated) {
            decodeImage(at: file.url, maxPixelSize: maxPixelSize)
        }.value

        if let image, let cgImage = image.cgImage {
            decodedImages.setObject(image, forKey: cacheKey(photo, maxPixelSize), cost: cgImage.bytesPerRow * cgImage.height)
        }
        return image
    }

    /// Fixed size, so a crafted width and height cannot make decoding expensive.
    static func placeholder(blurhash: String) -> UIImage? {
        if let image = placeholders.object(forKey: blurhash as NSString) {
            return image
        }
        guard let image = UIImage(blurHash: blurhash, size: CGSize(width: placeholderSize, height: placeholderSize)) else {
            return nil
        }
        placeholders.setObject(image, forKey: blurhash as NSString)
        return image
    }

    /// The event is not trusted: the file's size, type and pixel size are checked before anything is decoded.
    private nonisolated static func decodeImage(at url: URL?, maxPixelSize: Int) -> UIImage? {
        guard let url,
              let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              fileSize <= ChatBackground.Photo.maxSize,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source),
              decodableTypes.contains(type as String),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              (1...maxDecodedEdge).contains(width),
              (1...maxDecodedEdge).contains(height),
              let image = ChatBackgroundImageProcessor.uprightImage(from: source, maxPixelSize: min(maxPixelSize, ChatBackgroundImageProcessor.maxEdge)) else {
            return nil
        }
        return UIImage(cgImage: image)
    }

    private static func mediaSource(for photo: ChatBackground.Photo) -> MediaSourceProxy? {
        URL(string: photo.url).flatMap { try? MediaSourceProxy(url: $0, mimeType: photo.mimetype) }
    }

    private static func cacheKey(_ photo: ChatBackground.Photo, _ maxPixelSize: Int) -> NSString {
        "\(photo.url){\(min(maxPixelSize, ChatBackgroundImageProcessor.maxEdge))}" as NSString
    }
}
