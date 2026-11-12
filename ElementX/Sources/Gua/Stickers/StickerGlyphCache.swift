//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// The uploaded sticker of each keyboard glyph, so the same glyph uploads once per device.
final class StickerGlyphCache {
    private let file: SessionFile
    private var images: [String: StickerImage]
    
    init(file: SessionFile) {
        self.file = file
        images = file.read().flatMap { try? JSONDecoder().decode([String: StickerImage].self, from: $0) } ?? [:]
    }
    
    convenience init(directory: URL) {
        self.init(file: SessionFile(url: directory.appending(path: "gua-sticker-glyphs.json")))
    }
    
    func image(forContentIdentifier contentIdentifier: String) -> StickerImage? {
        images[contentIdentifier]
    }
    
    func store(_ image: StickerImage, forContentIdentifier contentIdentifier: String) {
        images[contentIdentifier] = image
        if let data = try? JSONEncoder().encode(images) {
            file.write(data)
        }
    }
}
