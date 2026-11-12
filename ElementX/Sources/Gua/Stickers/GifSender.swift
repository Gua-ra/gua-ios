//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import MatrixRustSDK
import SwiftUI
import UniformTypeIdentifiers

enum GifSenderError: Error {
    case noRendition
    case downloadFailed(GifProviderError)
    case invalidImage
    case sendFailed(TimelineControllerError)
}

// sourcery: AutoMockable
protocol GifSenderProtocol {
    /// Sends the provider's file as is through the send queue, so it gets a local echo, retry and encrypted media.
    func send(_ item: GifItem, caption: String?, inReplyToEventID: String?) async -> Result<Void, GifSenderError>
}

final class GifSender: GifSenderProtocol {
    private let provider: GifProvider
    private let timelineController: TimelineControllerProtocol
    private let temporaryDirectory: URL
    
    init(provider: GifProvider, timelineController: TimelineControllerProtocol, temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.provider = provider
        self.timelineController = timelineController
        self.temporaryDirectory = temporaryDirectory
    }
    
    func send(_ item: GifItem, caption: String?, inReplyToEventID: String?) async -> Result<Void, GifSenderError> {
        guard let choice = item.sendChoice else { return .failure(.noRendition) }
        
        async let animatedDownload = provider.data(from: choice.animated.url)
        async let stillDownload = provider.data(from: choice.still.url)
        let animatedData: Data
        let stillData: Data
        switch await (animatedDownload, stillDownload) {
        case (.success(let animated), .success(let still)):
            (animatedData, stillData) = (animated, still)
        case (.failure(let error), _), (_, .failure(let error)):
            return .failure(.downloadFailed(error))
        }
        
        guard let animated = DownloadedImage(data: animatedData), let still = DownloadedImage(data: stillData) else {
            return .failure(.invalidImage)
        }
        
        let folder = temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let imageURL = folder.appending(path: Self.filename(for: choice.body))
        let thumbnailURL = folder.appending(path: "thumbnail.jpg")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try animatedData.write(to: imageURL)
            try stillData.write(to: thumbnailURL)
        } catch {
            MXLog.error("Failed writing the GIF to send: \(error)")
            return .failure(.invalidImage)
        }
        
        let imageInfo = ImageInfo(height: UInt64(animated.height),
                                  width: UInt64(animated.width),
                                  mimetype: animated.mimeType ?? "image/webp",
                                  size: UInt64(animatedData.count),
                                  thumbnailInfo: ThumbnailInfo(height: UInt64(still.height),
                                                               width: UInt64(still.width),
                                                               mimetype: still.mimeType ?? "image/jpeg",
                                                               size: UInt64(stillData.count)),
                                  thumbnailSource: nil,
                                  blurhash: UIImage(data: stillData)?.blurHash(numberOfComponents: (3, 3)),
                                  isAnimated: true)
        
        return await timelineController.sendAnimatedImage(url: imageURL,
                                                          thumbnailURL: thumbnailURL,
                                                          imageInfo: imageInfo,
                                                          caption: caption,
                                                          inReplyToEventID: inReplyToEventID)
            .mapError(GifSenderError.sendFailed)
    }
    
    /// Without a caption the file name is the message body, so it is the title without an extension.
    static func filename(for body: String) -> String {
        let name = body.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)).joined(separator: " ")
        let trimmed = String(name.trimmingCharacters(in: .whitespaces).prefix(100))
        return trimmed.isEmpty || trimmed.hasPrefix(".") ? GifSendChoice.defaultBody : trimmed
    }
}

private nonisolated struct DownloadedImage {
    let width: Int
    let height: Int
    let mimeType: String?
    
    init?(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        self.width = width
        self.height = height
        mimeType = (CGImageSourceGetType(source) as String?).flatMap { UTType($0)?.preferredMIMEType }
    }
}
