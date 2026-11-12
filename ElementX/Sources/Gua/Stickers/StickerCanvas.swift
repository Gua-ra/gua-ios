//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

nonisolated enum StickerCanvas {
    static let side: CGFloat = 512
    static let outlineWidth: CGFloat = 6
    static let textMargin: CGFloat = 24
    static let maxFontSize: CGFloat = 64
    
    /// The image aspect-fits the canvas at scale 1, then is scaled about the centre and moved, in canvas units.
    static func imageRect(imageSize: CGSize, scale: CGFloat, offset: CGSize) -> CGRect {
        let fit = min(side / max(imageSize.width, 1), side / max(imageSize.height, 1)) * scale
        let size = CGSize(width: imageSize.width * fit, height: imageSize.height * fit)
        return CGRect(x: (side - size.width) / 2 + offset.width,
                      y: (side - size.height) / 2 + offset.height,
                      width: size.width,
                      height: size.height)
    }
    
    /// The image pixel under a canvas point, nil outside the image. Both are measured from the top left.
    static func imagePoint(forCanvasPoint point: CGPoint, imageSize: CGSize, scale: CGFloat, offset: CGSize) -> CGPoint? {
        let rect = imageRect(imageSize: imageSize, scale: scale, offset: offset)
        guard rect.contains(point), rect.width > 0, rect.height > 0 else { return nil }
        return CGPoint(x: (point.x - rect.minX) / rect.width * imageSize.width,
                       y: (point.y - rect.minY) / rect.height * imageSize.height)
    }
    
    static func render(_ image: CGImage, outlined: Bool, scale: CGFloat, offset: CGSize, text: String) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let rect = imageRect(imageSize: CGSize(width: image.width, height: image.height), scale: scale, offset: offset)
        let source = UIImage(cgImage: image)
        
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            if outlined, let silhouette = silhouette(of: source) {
                for step in 0..<16 {
                    let angle = Double(step) / 16 * 2 * .pi
                    silhouette.draw(in: rect.offsetBy(dx: cos(angle) * outlineWidth, dy: sin(angle) * outlineWidth))
                }
            }
            source.draw(in: rect)
            draw(text, in: context.cgContext)
        }
        return rendered.cgImage
    }
    
    private static func silhouette(of image: UIImage) -> UIImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: image.size, format: format).image { context in
            image.draw(at: .zero)
            context.cgContext.setBlendMode(.sourceIn)
            context.cgContext.setFillColor(UIColor.white.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: image.size))
        }
    }
    
    private static func draw(_ text: String, in context: CGContext) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        
        let maxWidth = side - 2 * textMargin
        var fontSize = maxFontSize
        var attributes = textAttributes(fontSize: fontSize)
        while (text as NSString).size(withAttributes: attributes).width > maxWidth, fontSize > 12 {
            fontSize -= 2
            attributes = textAttributes(fontSize: fontSize)
        }
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = CGPoint(x: (side - min(size.width, maxWidth)) / 2, y: side - textMargin - size.height)
        let frame = CGRect(origin: origin, size: CGSize(width: min(size.width, maxWidth), height: size.height))
        
        var outline = attributes
        outline[.strokeColor] = UIColor.black.withAlphaComponent(0.85)
        outline[.strokeWidth] = 24
        (text as NSString).draw(with: frame, options: .truncatesLastVisibleLine, attributes: outline, context: nil)
        (text as NSString).draw(with: frame, options: .truncatesLastVisibleLine, attributes: attributes, context: nil)
    }
    
    private static func textAttributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: UIFont.systemFont(ofSize: fontSize, weight: .heavy), .foregroundColor: UIColor.white]
    }
}

nonisolated extension StickerCutout {
    func subject(at point: CGPoint) -> Int? {
        let x = Int(point.x), y = Int(point.y)
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
        
        return subjectMasks.firstIndex { mask in
            var value: UInt8 = 0
            guard let context = CGContext(data: &value,
                                          width: 1,
                                          height: 1,
                                          bitsPerComponent: 8,
                                          bytesPerRow: 1,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                return false
            }
            let scaleX = CGFloat(mask.width) / CGFloat(image.width)
            let scaleY = CGFloat(mask.height) / CGFloat(image.height)
            // Moves the pixel to the context's only pixel, whose origin is at the bottom left.
            context.draw(mask, in: CGRect(x: -CGFloat(x) * scaleX,
                                          y: -CGFloat(mask.height) + CGFloat(y) * scaleY + 1,
                                          width: CGFloat(mask.width),
                                          height: CGFloat(mask.height)))
            return value > 127
        }
    }
}
