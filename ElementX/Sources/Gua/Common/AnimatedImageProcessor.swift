//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import ImageIO
import Kingfisher
import SwiftUI

/// Kingfisher's animated path for every format ImageIO can read, as its default processor only animates GIF and
/// reads frame delays from the GIF dictionary alone.
nonisolated struct AnimatedImageProcessor: ImageProcessor {
    let identifier = "global.gua.animated-image"
    
    func process(item: ImageProcessItem, options: KingfisherParsedOptionsInfo) -> KFCrossPlatformImage? {
        switch item {
        case .image(let image):
            return image
        case .data(let data):
            guard let frameSource = AnimatedImageFrameSource(data: data), frameSource.frameCount > 1 else {
                return UIImage(data: data, scale: options.scaleFactor)
            }
            let creatingOptions = ImageCreatingOptions(scale: options.scaleFactor,
                                                       preloadAll: options.preloadAllAnimationData,
                                                       onlyFirstFrame: options.onlyLoadFirstFrame)
            return KingfisherWrapper.animatedImage(source: frameSource, options: creatingOptions)
        }
    }
}

private nonisolated struct AnimatedImageFrameSource: ImageFrameSource {
    static let defaultFrameDuration = 0.1
    
    let data: Data?
    private let imageSource: CGImageSource
    
    var frameCount: Int {
        CGImageSourceGetCount(imageSource)
    }
    
    init?(data: Data) {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: true] as CFDictionary) else {
            return nil
        }
        self.data = data
        self.imageSource = imageSource
    }
    
    func frame(at index: Int, maxSize: CGSize?) -> CGImage? {
        CGImageSourceCreateImageAtIndex(imageSource, index, nil)
    }
    
    func duration(at index: Int) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, index, nil) as? [CFString: Any] else {
            return Self.defaultFrameDuration
        }
        let frameInfo = [(kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
                         (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
                         (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime)]
        for (dictionaryKey, unclampedKey, clampedKey) in frameInfo {
            guard let dictionary = properties[dictionaryKey] as? [CFString: Any],
                  let delay = (dictionary[unclampedKey] ?? dictionary[clampedKey]) as? Double else {
                continue
            }
            // Browsers play delays under 11 ms at 100 ms, which is what the files' authors expect.
            return delay > 0.011 ? delay : Self.defaultFrameDuration
        }
        return Self.defaultFrameDuration
    }
    
    func copy() -> AnimatedImageFrameSource {
        data.flatMap(AnimatedImageFrameSource.init) ?? self
    }
}
