//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns any image into a sticker file: transparent edges trimmed, fitted into 512×512 with 16 px padding, as PNG,
/// since ImageIO can't write WebP.
nonisolated enum StickerImageEncoder {
    static let maxSide = 512
    static let padding = 16
    static let maxFileSize = 300_000
    static let minSide = 128
    
    static func stickerFile(from image: CGImage) -> StickerFile? {
        guard let trimmed = trimmedRect(of: image).flatMap(image.cropping) else { return nil }
        
        var side = maxSide
        var file: StickerFile?
        repeat {
            guard let rendered = render(trimmed, side: side), let data = pngData(rendered) else { return file }
            file = StickerFile(data: data, mimeType: "image/png", pixelWidth: rendered.width, pixelHeight: rendered.height, isAnimated: false)
            side = side * 4 / 5
        } while (file?.data.count ?? 0) > maxFileSize && side >= minSide
        return file
    }
    
    static func trimmedRect(of image: CGImage) -> CGRect? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        
        var minX = width, minY = height, maxX = -1, maxY = -1
        for row in 0..<height {
            for column in 0..<width where pixels[row * width * 4 + column * 4 + 3] > 0 {
                minX = min(minX, column)
                maxX = max(maxX, column)
                minY = min(minY, row)
                maxY = max(maxY, row)
            }
        }
        guard maxX >= 0 else { return nil }
        // The bitmap's first row is the top of the image, as CGImage cropping expects.
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
    
    static func layout(contentWidth: Int, contentHeight: Int, side: Int) -> (canvas: CGSize, content: CGRect) {
        let padding = Double(padding * side) / Double(maxSide)
        let scale = (Double(side) - 2 * padding) / Double(max(contentWidth, contentHeight, 1))
        let width = max(1, (Double(contentWidth) * scale).rounded())
        let height = max(1, (Double(contentHeight) * scale).rounded())
        let paddingInPixels = padding.rounded()
        return (CGSize(width: width + 2 * paddingInPixels, height: height + 2 * paddingInPixels),
                CGRect(x: paddingInPixels, y: paddingInPixels, width: width, height: height))
    }
    
    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
    
    private static func render(_ image: CGImage, side: Int) -> CGImage? {
        let layout = layout(contentWidth: image.width, contentHeight: image.height, side: side)
        guard let context = CGContext(data: nil,
                                      width: Int(layout.canvas.width),
                                      height: Int(layout.canvas.height),
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: layout.content)
        return context.makeImage()
    }
}
