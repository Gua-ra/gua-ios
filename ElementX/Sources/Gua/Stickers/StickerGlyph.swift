//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import ImageIO
import SwiftUI

nonisolated struct StickerGlyph: Sendable {
    let imageContent: Data
    /// The same glyph always has the same identifier, which keys the upload cache.
    let contentIdentifier: String
    let contentDescription: String
    
    var body: String {
        let description = contentDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? StickerMessageContent.defaultBody : description
    }
    
    init(_ glyph: NSAdaptiveImageGlyph) {
        self.init(imageContent: glyph.imageContent, contentIdentifier: glyph.contentIdentifier, contentDescription: glyph.contentDescription)
    }
    
    init(imageContent: Data, contentIdentifier: String, contentDescription: String) {
        self.imageContent = imageContent
        self.contentIdentifier = contentIdentifier
        self.contentDescription = contentDescription
    }
    
    func stickerFile() -> StickerFile? {
        Self.largestImage(in: imageContent).flatMap(StickerImageEncoder.stickerFile(from:))
    }
    
    static func largestImage(in data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let index = (0..<CGImageSourceGetCount(source)).max { pixelCount(source, $0) < pixelCount(source, $1) }
        return index.flatMap { CGImageSourceCreateImageAtIndex(source, $0, nil) }
    }
    
    private static func pixelCount(_ source: CGImageSource, _ index: Int) -> Int {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return 0
        }
        return width * height
    }
}
