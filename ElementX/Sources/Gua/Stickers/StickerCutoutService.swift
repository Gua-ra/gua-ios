//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import CoreImage
import Synchronization
import Vision

/// The subjects found in a photo, each as a mask aligned with `image`.
nonisolated struct StickerCutout: Sendable {
    /// The photo scaled down to the size the masks were made at.
    let image: CGImage
    /// Greyscale, white where the subject is.
    let subjectMasks: [CGImage]
    
    func maskedImage(subjects: IndexSet) -> CGImage? {
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let maskContext = CGContext(data: nil,
                                          width: image.width,
                                          height: image.height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue),
            let imageContext = CGContext(data: nil,
                                         width: image.width,
                                         height: image.height,
                                         bitsPerComponent: 8,
                                         bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        maskContext.setFillColor(gray: 0, alpha: 1)
        maskContext.fill(rect)
        maskContext.setBlendMode(.lighten)
        for index in subjects where subjectMasks.indices.contains(index) {
            maskContext.draw(subjectMasks[index], in: rect)
        }
        guard let mask = maskContext.makeImage() else { return nil }
        
        imageContext.clip(to: rect, mask: mask)
        imageContext.draw(image, in: rect)
        return imageContext.makeImage()
    }
}

// sourcery: AutoMockable
nonisolated protocol StickerCutoutServiceProtocol: Sendable {
    /// Nil when nothing was found, on failure, after the timeout and in the simulator.
    func cutout(of image: CGImage) async -> StickerCutout?
}

/// Vision's foreground instance masks, with every instance kept apart so each subject can be toggled.
final nonisolated class StickerCutoutService: StickerCutoutServiceProtocol {
    private let timeout: Duration
    private let maxPixelSide: Int
    
    init(timeout: Duration = .seconds(5), maxPixelSide: Int = 1024) {
        self.timeout = timeout
        self.maxPixelSide = maxPixelSide
    }
    
    func cutout(of image: CGImage) async -> StickerCutout? {
        #if targetEnvironment(simulator)
        return nil
        #else
        let maxPixelSide = maxPixelSide
        let timeout = timeout
        // Vision can't be cancelled, so the timeout answers without waiting for it.
        return await withCheckedContinuation { continuation in
            let result = FirstResult(continuation)
            Task.detached(priority: .userInitiated) {
                result.resume(returning: Self.makeCutout(of: image, maxPixelSide: maxPixelSide))
            }
            Task.detached {
                try? await Task.sleep(for: timeout)
                result.resume(returning: nil)
            }
        }
        #endif
    }
    
    private static func makeCutout(of image: CGImage, maxPixelSide: Int) -> StickerCutout? {
        guard let working = scaled(image, maxPixelSide: maxPixelSide) else { return nil }
        
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: working)
        do {
            try handler.perform([request])
        } catch {
            MXLog.error("Failed finding the sticker subjects: \(error)")
            return nil
        }
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { return nil }
        
        let context = CIContext()
        let masks = observation.allInstances.compactMap { instance -> CGImage? in
            guard let buffer = try? observation.generateScaledMaskForImage(forInstances: IndexSet(integer: instance), from: handler) else {
                return nil
            }
            let mask = CIImage(cvPixelBuffer: buffer)
            return context.createCGImage(mask, from: mask.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        }
        return masks.isEmpty ? nil : StickerCutout(image: working, subjectMasks: masks)
    }
    
    private static func scaled(_ image: CGImage, maxPixelSide: Int) -> CGImage? {
        let scale = min(1, Double(maxPixelSide) / Double(max(image.width, image.height, 1)))
        guard scale < 1 else { return image }
        
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

/// Resumes its continuation with whichever result arrives first.
private final nonisolated class FirstResult: Sendable {
    private let continuation: Mutex<CheckedContinuation<StickerCutout?, Never>?>
    
    init(_ continuation: CheckedContinuation<StickerCutout?, Never>) {
        self.continuation = Mutex(continuation)
    }
    
    func resume(returning cutout: StickerCutout?) {
        continuation.withLock { $0.take() }?.resume(returning: cutout)
    }
}
