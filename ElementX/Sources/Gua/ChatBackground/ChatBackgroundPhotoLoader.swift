//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import ImageIO
import UIKit

@MainActor
enum ChatBackgroundPhotoLoader {
    private static let decodedImages = NSCache<NSString, UIImage>()
    private static let placeholders = NSCache<NSString, UIImage>()
    private static let placeholderSize = 32

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

        if let image {
            decodedImages.setObject(image, forKey: cacheKey(photo, maxPixelSize))
        }
        return image
    }

    /// Decoded at a fixed size whatever shape the photo declares, so a crafted width and height cannot make it expensive.
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

    /// The declared size is not trusted: the file on disk is checked before anything is decoded.
    nonisolated static func decodeImage(at url: URL?, maxPixelSize: Int) -> UIImage? {
        guard let url,
              let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              fileSize <= ChatBackground.Photo.maxSize,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = ChatBackgroundImageProcessor.uprightImage(from: source, maxPixelSize: min(maxPixelSize, ChatBackgroundImageProcessor.maxEdge)) else {
            return nil
        }
        return UIImage(cgImage: image)
    }

    private static func mediaSource(for photo: ChatBackground.Photo) -> MediaSourceProxy? {
        URL(string: photo.url).flatMap { try? MediaSourceProxy(url: $0, mimeType: photo.mimetype) }
    }

    private static func cacheKey(_ photo: ChatBackground.Photo, _ maxPixelSize: Int) -> NSString {
        "\(photo.url){\(maxPixelSize)}" as NSString
    }
}
