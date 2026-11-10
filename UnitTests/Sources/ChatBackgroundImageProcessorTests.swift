//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

final class ChatBackgroundImageProcessorTests {
    /// ImageIO always writes these from the pixels themselves, and nothing else may survive from the original.
    private let allowedExifKeys: Set<String> = [kCGImagePropertyExifColorSpace as String,
                                                kCGImagePropertyExifPixelXDimension as String,
                                                kCGImagePropertyExifPixelYDimension as String]
    
    @Test
    func largePhotoIsUprightDownscaledSRGBAndStripped() throws {
        let original = try makeJPEG(width: 4000, height: 3000, colorSpace: CGColorSpace(name: CGColorSpace.displayP3), orientation: .right)
        #expect(properties(of: original)[kCGImagePropertyGPSDictionary as String] != nil)
        
        let upload = try ChatBackgroundImageProcessor.process(original)
        
        #expect(upload.width == 1536)
        #expect(upload.height == 2048)
        #expect(upload.blurhash != nil)
        
        let source = try #require(CGImageSourceCreateWithData(upload.data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 1536)
        #expect(image.height == 2048)
        #expect(image.colorSpace?.name == CGColorSpace.sRGB)
        
        let written = properties(of: upload.data)
        #expect(written[kCGImagePropertyGPSDictionary as String] == nil)
        #expect(written[kCGImagePropertyTIFFDictionary as String] == nil)
        #expect(written[kCGImagePropertyIPTCDictionary as String] == nil)
        #expect(written[kCGImagePropertyMakerAppleDictionary as String] == nil)
        #expect(written[kCGImagePropertyOrientation as String] == nil)
        let exif = written[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        #expect(Set(exif.keys).isSubset(of: allowedExifKeys), "Unexpected Exif keys: \(exif.keys.sorted())")
        if let profileName = written[kCGImagePropertyProfileName as String] as? String {
            #expect(profileName.contains("sRGB"), "\(profileName)")
        }
    }
    
    @Test
    func smallPhotoIsNeverUpscaled() throws {
        let original = try makeJPEG(width: 800, height: 600)
        
        let upload = try ChatBackgroundImageProcessor.process(original)
        
        #expect(upload.width == 800)
        #expect(upload.height == 600)
    }
    
    @Test
    func heavyPhotoIsReencodedSmaller() throws {
        let original = try makeJPEG(width: 3000, height: 3000, isNoise: true)
        
        let upload = try ChatBackgroundImageProcessor.process(original)
        
        #expect(max(upload.width, upload.height) == ChatBackgroundImageProcessor.reducedMaxEdge)
    }
    
    @Test
    func transparencyIsFlattenedOntoBlack() throws {
        let original = try makeImage(width: 64, height: 64, type: .png, alpha: 0)
        
        let upload = try ChatBackgroundImageProcessor.process(original)
        
        let source = try #require(CGImageSourceCreateWithData(upload.data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let pixel = try #require(centrePixel(of: image))
        #expect(pixel.allSatisfy { $0 < 8 }, "\(pixel)")
    }
    
    @Test
    func unreadableDataFails() {
        #expect(throws: (any Error).self) { try ChatBackgroundImageProcessor.process(Data("not an image".utf8)) }
    }
    
    @MainActor
    @Test
    func placeholderIsDecodedAtAFixedSize() throws {
        let placeholder = try #require(ChatBackgroundPhotoLoader.placeholder(blurhash: "LKO2?U%2Tw=w]~RBVZRi};RPxuwH"))
        #expect(placeholder.size.width * placeholder.scale == 32)
        #expect(placeholder.size.height * placeholder.scale == 32)
        #expect(ChatBackgroundPhotoLoader.placeholder(blurhash: "not a hash") == nil)
    }
    
    private func properties(of data: Data) -> [String: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
    }
    
    private func makeJPEG(width: Int,
                          height: Int,
                          colorSpace: CGColorSpace? = CGColorSpace(name: CGColorSpace.sRGB),
                          orientation: CGImagePropertyOrientation = .up,
                          isNoise: Bool = false) throws -> Data {
        try makeImage(width: width, height: height, type: .jpeg, colorSpace: colorSpace, orientation: orientation, isNoise: isNoise)
    }
    
    private func makeImage(width: Int,
                           height: Int,
                           type: UTType,
                           colorSpace: CGColorSpace? = CGColorSpace(name: CGColorSpace.sRGB),
                           orientation: CGImagePropertyOrientation = .up,
                           alpha: CGFloat = 1,
                           isNoise: Bool = false) throws -> Data {
        let colorSpace = try #require(colorSpace)
        let context = try #require(CGContext(data: nil,
                                             width: width,
                                             height: height,
                                             bitsPerComponent: 8,
                                             bytesPerRow: 0,
                                             space: colorSpace,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        if isNoise, let pixels = context.data?.assumingMemoryBound(to: UInt8.self) {
            var generator = SystemRandomNumberGenerator()
            for index in 0..<(context.bytesPerRow * height) {
                pixels[index] = index % 4 == 3 ? 255 : UInt8.random(in: 0...255, using: &generator)
            }
        } else {
            context.setFillColor(CGColor(red: 0.2, green: 0.8, blue: 0.4, alpha: alpha))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let image = try #require(context.makeImage())
        
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        let metadata: [CFString: Any] = [kCGImagePropertyOrientation: orientation.rawValue,
                                         kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 45.5017,
                                                                         kCGImagePropertyGPSLatitudeRef: "N",
                                                                         kCGImagePropertyGPSLongitude: 73.5673,
                                                                         kCGImagePropertyGPSLongitudeRef: "W"],
                                         kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple",
                                                                          kCGImagePropertyTIFFModel: "iPhone 17 Pro"],
                                         kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "Back camera",
                                                                          kCGImagePropertyExifDateTimeOriginal: "2026:11:03 12:00:00"],
                                         kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: "Private caption"],
                                         kCGImagePropertyMakerAppleDictionary: ["1": 1]]
        CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
    
    private func centrePixel(of image: CGImage) -> [UInt8]? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil,
                                      width: 1,
                                      height: 1,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return [pixels[0], pixels[1], pixels[2]]
    }
}
