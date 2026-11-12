//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import CoreGraphics
@testable import ElementX
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

final class StickerImageEncoderTests {
    @Test
    func transparentEdgesAreTrimmed() throws {
        let image = try Self.image(width: 100, height: 80, opaqueRect: CGRect(x: 10, y: 20, width: 30, height: 40))
        
        #expect(StickerImageEncoder.trimmedRect(of: image) == CGRect(x: 10, y: 20, width: 30, height: 40))
    }
    
    @Test
    func fullyTransparentImageMakesNoSticker() throws {
        let image = try Self.image(width: 50, height: 50, opaqueRect: nil)
        
        #expect(StickerImageEncoder.trimmedRect(of: image) == nil)
        #expect(StickerImageEncoder.stickerFile(from: image) == nil)
    }
    
    @Test
    func contentFitsIn512With16PixelsOfPadding() {
        let wide = StickerImageEncoder.layout(contentWidth: 300, contentHeight: 150, side: 512)
        #expect(wide.canvas == CGSize(width: 512, height: 272))
        #expect(wide.content == CGRect(x: 16, y: 16, width: 480, height: 240))
        
        let small = StickerImageEncoder.layout(contentWidth: 40, contentHeight: 80, side: 512)
        #expect(small.canvas == CGSize(width: 272, height: 512))
        #expect(small.content == CGRect(x: 16, y: 16, width: 240, height: 480))
        
        let shrunk = StickerImageEncoder.layout(contentWidth: 100, contentHeight: 100, side: 256)
        #expect(shrunk.canvas == CGSize(width: 256, height: 256))
        #expect(shrunk.content == CGRect(x: 8, y: 8, width: 240, height: 240))
    }
    
    @Test
    func stickerIsATrimmedPaddedPNG() throws {
        let image = try Self.image(width: 1000, height: 600, opaqueRect: CGRect(x: 100, y: 100, width: 400, height: 200))
        
        let file = try #require(StickerImageEncoder.stickerFile(from: image))
        
        #expect(file.mimeType == "image/png")
        #expect(!file.isAnimated)
        #expect(file.pixelWidth == 512)
        #expect(file.pixelHeight == 272)
        let source = try #require(CGImageSourceCreateWithData(file.data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier)
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(StickerImageEncoder.trimmedRect(of: decoded) == CGRect(x: 16, y: 16, width: 480, height: 240))
    }
    
    @Test
    func largeFilesAreReencodedSmaller() throws {
        let noise = try Self.noise(width: 512, height: 512)
        #expect(try #require(StickerImageEncoder.pngData(noise)).count > StickerImageEncoder.maxFileSize)
        
        let file = try #require(StickerImageEncoder.stickerFile(from: noise))
        
        #expect(file.data.count <= StickerImageEncoder.maxFileSize)
        #expect(file.pixelWidth < 512)
        #expect(file.pixelWidth == file.pixelHeight)
    }
    
    @Test
    func glyphUsesItsLargestImage() throws {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 3, nil))
        for side in [40, 160, 80] {
            try CGImageDestinationAddImage(destination, Self.image(width: side, height: side, opaqueRect: CGRect(x: 0, y: 0, width: side, height: side)), nil)
        }
        #expect(CGImageDestinationFinalize(destination))
        
        let glyph = StickerGlyph(imageContent: data as Data, contentIdentifier: "glyph-1", contentDescription: " Smiling cat ")
        
        #expect(StickerGlyph.largestImage(in: data as Data)?.width == 160)
        #expect(glyph.body == "Smiling cat")
        #expect(StickerGlyph(imageContent: Data(), contentIdentifier: "glyph-2", contentDescription: "").body == "Sticker")
        let file = try #require(glyph.stickerFile())
        #expect(file.pixelWidth == 512)
        #expect(file.pixelHeight == 512)
    }
    
    @Test
    func cutoutKeepsOnlyTheChosenSubjects() throws {
        let photo = try Self.image(width: 20, height: 10, opaqueRect: CGRect(x: 0, y: 0, width: 20, height: 10))
        let left = try Self.mask(width: 20, height: 10, whiteRect: CGRect(x: 0, y: 0, width: 5, height: 10))
        let right = try Self.mask(width: 20, height: 10, whiteRect: CGRect(x: 15, y: 0, width: 5, height: 10))
        let cutout = StickerCutout(image: photo, subjectMasks: [left, right])
        
        let both = try #require(cutout.maskedImage(subjects: [0, 1]))
        let onlyRight = try #require(cutout.maskedImage(subjects: [1]))
        
        #expect(StickerImageEncoder.trimmedRect(of: both) == CGRect(x: 0, y: 0, width: 20, height: 10))
        #expect(StickerImageEncoder.trimmedRect(of: onlyRight) == CGRect(x: 15, y: 0, width: 5, height: 10))
        #expect(cutout.maskedImage(subjects: []).flatMap(StickerImageEncoder.trimmedRect) == nil)
    }
    
    @Test
    func cutoutGivesUpInTheSimulator() async throws {
        let photo = try Self.image(width: 20, height: 10, opaqueRect: CGRect(x: 0, y: 0, width: 20, height: 10))
        
        #if targetEnvironment(simulator)
        #expect(await StickerCutoutService().cutout(of: photo) == nil)
        #endif
    }
    
    /// Opaque red inside `opaqueRect`, measured from the top left, and transparent elsewhere.
    private static func image(width: Int, height: Int, opaqueRect: CGRect?) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        if let opaqueRect {
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: opaqueRect.minX, y: CGFloat(height) - opaqueRect.maxY, width: opaqueRect.width, height: opaqueRect.height))
        }
        return try #require(context.makeImage())
    }
    
    private static func mask(width: Int, height: Int, whiteRect: CGRect) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: whiteRect.minX, y: CGFloat(height) - whiteRect.maxY, width: whiteRect.width, height: whiteRect.height))
        return try #require(context.makeImage())
    }
    
    private static func noise(width: Int, height: Int) throws -> CGImage {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<(width * height * 4)).map { index in index % 4 == 3 ? UInt8(255) : UInt8.random(in: 0...255, using: &generator) }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
}
