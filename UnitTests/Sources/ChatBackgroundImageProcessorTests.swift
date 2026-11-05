//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class ChatBackgroundImageProcessorTests: XCTestCase {
    /// ImageIO always writes these from the pixels themselves, and nothing else may survive from the original.
    private let allowedExifKeys: Set<String> = [kCGImagePropertyExifColorSpace as String,
                                                kCGImagePropertyExifPixelXDimension as String,
                                                kCGImagePropertyExifPixelYDimension as String]

    func testLargePhotoIsUprightDownscaledSRGBAndStripped() throws {
        let original = try makeJPEG(width: 4000, height: 3000, colorSpace: CGColorSpace(name: CGColorSpace.displayP3), orientation: .right)
        XCTAssertNotNil(properties(of: original)[kCGImagePropertyGPSDictionary as String])

        let upload = try ChatBackgroundImageProcessor.process(original)

        XCTAssertEqual(upload.width, 1536)
        XCTAssertEqual(upload.height, 2048)
        XCTAssertNotNil(upload.blurhash)
        XCTAssertEqual(ChatBackgroundPhotoUpload.mimetype, "image/jpeg")

        let source = try XCTUnwrap(CGImageSourceCreateWithData(upload.data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 1536)
        XCTAssertEqual(image.height, 2048)
        XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB)

        let written = properties(of: upload.data)
        XCTAssertNil(written[kCGImagePropertyGPSDictionary as String])
        XCTAssertNil(written[kCGImagePropertyTIFFDictionary as String])
        XCTAssertNil(written[kCGImagePropertyIPTCDictionary as String])
        XCTAssertNil(written[kCGImagePropertyMakerAppleDictionary as String])
        XCTAssertNil(written[kCGImagePropertyOrientation as String])
        let exif = written[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        XCTAssertTrue(Set(exif.keys).isSubset(of: allowedExifKeys), "Unexpected Exif keys: \(exif.keys.sorted())")
        if let profileName = written[kCGImagePropertyProfileName as String] as? String {
            XCTAssertTrue(profileName.contains("sRGB"), profileName)
        }
    }

    func testSmallPhotoIsNeverUpscaled() throws {
        let original = try makeJPEG(width: 800, height: 600)

        let upload = try ChatBackgroundImageProcessor.process(original)

        XCTAssertEqual(upload.width, 800)
        XCTAssertEqual(upload.height, 600)
    }

    func testHeavyPhotoIsReencodedSmaller() throws {
        let original = try makeJPEG(width: 3000, height: 3000, isNoise: true)

        let upload = try ChatBackgroundImageProcessor.process(original)

        XCTAssertEqual(max(upload.width, upload.height), ChatBackgroundImageProcessor.reducedMaxEdge)
    }

    func testTransparencyIsFlattenedOntoBlack() throws {
        let original = try makeImage(width: 64, height: 64, type: .png, alpha: 0)

        let upload = try ChatBackgroundImageProcessor.process(original)

        let source = try XCTUnwrap(CGImageSourceCreateWithData(upload.data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let pixel = try XCTUnwrap(centrePixel(of: image))
        XCTAssertTrue(pixel.allSatisfy { $0 < 8 }, "\(pixel)")
    }

    func testUnreadableDataFails() {
        XCTAssertThrowsError(try ChatBackgroundImageProcessor.process(Data("not an image".utf8)))
    }

    @MainActor
    func testPlaceholderIsDecodedAtAFixedSize() throws {
        let placeholder = try XCTUnwrap(ChatBackgroundPhotoLoader.placeholder(blurhash: "LKO2?U%2Tw=w]~RBVZRi};RPxuwH"))
        XCTAssertEqual(placeholder.size.width * placeholder.scale, 32)
        XCTAssertEqual(placeholder.size.height * placeholder.scale, 32)
        XCTAssertNil(ChatBackgroundPhotoLoader.placeholder(blurhash: "not a hash"))
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
        let colorSpace = try XCTUnwrap(colorSpace)
        let context = try XCTUnwrap(CGContext(data: nil,
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
        let image = try XCTUnwrap(context.makeImage())

        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
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
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// The red, green and blue of the pixel at the centre.
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
