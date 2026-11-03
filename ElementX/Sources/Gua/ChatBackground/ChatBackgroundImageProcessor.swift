//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import ImageIO
import UIKit
import UniformTypeIdentifiers

struct ChatBackgroundPhotoUpload: Equatable {
    static let mimetype = "image/jpeg"

    let data: Data
    let width: Int
    let height: Int
    let blurhash: String?
}

enum ChatBackgroundImageProcessorError: Error {
    case unreadableImage
    case encodingFailed
}

/// Only decoded pixels are written, so nothing from the original file, EXIF and GPS included, reaches the upload.
enum ChatBackgroundImageProcessor {
    static let maxEdge = 2048
    static let reducedMaxEdge = 1600
    static let largeSize = 1_500_000

    private static let quality = 0.8
    private static let reducedQuality = 0.75
    private static let blurhashWidth = 64

    static func process(_ data: Data) throws -> ChatBackgroundPhotoUpload {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            throw ChatBackgroundImageProcessorError.unreadableImage
        }

        let upload = try encode(source, maxEdge: maxEdge, quality: quality)
        guard upload.data.count > largeSize else { return upload }
        return try encode(source, maxEdge: reducedMaxEdge, quality: reducedQuality)
    }

    static func uprightImage(from source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? maxPixelSize
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? maxPixelSize

        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(1, min(maxPixelSize, max(width, height)))]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func encode(_ source: CGImageSource, maxEdge: Int, quality: Double) throws -> ChatBackgroundPhotoUpload {
        guard let upright = uprightImage(from: source, maxPixelSize: maxEdge),
              let image = flattenedSRGBImage(upright, width: upright.width, height: upright.height) else {
            throw ChatBackgroundImageProcessorError.unreadableImage
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ChatBackgroundImageProcessorError.encodingFailed
        }
        // Never CGImageDestinationAddImageFromSource, which copies the original's metadata.
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ChatBackgroundImageProcessorError.encodingFailed
        }

        return ChatBackgroundPhotoUpload(data: data as Data,
                                         width: image.width,
                                         height: image.height,
                                         blurhash: blurhash(of: image))
    }

    /// The thumbnail keeps a Display P3 photo's profile, so the pixels are redrawn in sRGB, over black where transparent.
    private static func flattenedSRGBImage(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return nil
        }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(rect)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        return context.makeImage()
    }

    private static func blurhash(of image: CGImage) -> String? {
        let height = max(1, Int((Double(blurhashWidth) * Double(image.height) / Double(image.width)).rounded()))
        guard let small = flattenedSRGBImage(image, width: blurhashWidth, height: height) else { return nil }
        return UIImage(cgImage: small).blurHash(numberOfComponents: (3, 3))
    }
}
