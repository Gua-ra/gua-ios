//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

nonisolated enum StickerGlyphText {
    static let pasteboardTypes = ["com.apple.png-sticker", "com.apple.sticker"]
    
    enum Segment: Equatable {
        case text(String)
        case glyph(StickerGlyph)
    }
    
    enum Classification: Equatable {
        case none
        case single(StickerGlyph)
        case mixed(text: String, glyphs: [StickerGlyph])
    }
    
    static func segments(of text: NSAttributedString) -> [Segment] {
        var segments: [Segment] = []
        text.enumerateAttribute(.adaptiveImageGlyph, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let glyph = value as? NSAdaptiveImageGlyph {
                segments.append(.glyph(StickerGlyph(glyph)))
            } else {
                segments.append(.text(text.attributedSubstring(from: range).string))
            }
        }
        return segments
    }
    
    static func classify(_ segments: [Segment]) -> Classification {
        let glyphs = segments.compactMap { segment -> StickerGlyph? in
            if case .glyph(let glyph) = segment {
                glyph
            } else {
                nil
            }
        }
        guard !glyphs.isEmpty else { return .none }
        
        let text = segments.compactMap { segment -> String? in
            if case .text(let text) = segment {
                text
            } else {
                nil
            }
        }
        .joined()
        if glyphs.count == 1, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .single(glyphs[0])
        }
        return .mixed(text: text, glyphs: glyphs)
    }
    
    static func removingGlyphs(from text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        var ranges: [NSRange] = []
        text.enumerateAttribute(.adaptiveImageGlyph, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value != nil {
                ranges.append(range)
            }
        }
        for range in ranges.reversed() {
            result.deleteCharacters(in: range)
        }
        return result
    }
}

nonisolated extension StickerGlyph: Equatable {
    static func == (lhs: StickerGlyph, rhs: StickerGlyph) -> Bool {
        lhs.contentIdentifier == rhs.contentIdentifier
    }
}

extension UIPasteboard {
    /// A pasted Apple sticker, read now because the pasteboard can change before an async load finishes.
    var stickerItemProvider: NSItemProvider? {
        for type in StickerGlyphText.pasteboardTypes {
            if let data = data(forPasteboardType: type) {
                return NSItemProvider(item: data as NSData, typeIdentifier: type)
            }
        }
        return nil
    }
}

extension NSItemProvider {
    var isPastedSticker: Bool {
        StickerGlyphText.pasteboardTypes.contains(where: hasItemConformingToTypeIdentifier)
    }
}
