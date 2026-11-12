//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

@testable import ElementX
import Foundation
import ImageIO
import MatrixRustSDK
import Testing
import UniformTypeIdentifiers

@MainActor
final class GifSenderTests {
    /// A 1×1 lossless WebP.
    private static let webp = Data(base64Encoded: "UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA==") ?? Data()
    
    private let item = GifItem(id: "hello-42",
                               title: "Hello",
                               renditions: [.hd: GifRendition(name: .hd,
                                                              animated: GifFile(url: "https://static.klipy.com/hd.webp", width: 498, height: 280, size: 2_000_000),
                                                              still: GifFile(url: "https://static.klipy.com/hd.jpg", width: 498, height: 280, size: 16000)),
                                            .md: GifRendition(name: .md,
                                                              animated: GifFile(url: "https://static.klipy.com/md.webp", width: 320, height: 180, size: 300_000),
                                                              still: GifFile(url: "https://static.klipy.com/md.jpg", width: 320, height: 180, size: 9000))])
    
    private var provider: GifProviderMock!
    private var timelineController: TimelineControllerMock!
    private var sender: GifSender!
    private var sent: SentImage?
    
    init() throws {
        let jpeg = try Self.jpeg(width: 4, height: 3)
        provider = GifProviderMock()
        provider.dataFromClosure = { url in
            switch url.pathExtension {
            case "webp": .success(Self.webp)
            case "jpg": .success(jpeg)
            default: .failure(.disallowedURL)
            }
        }
        timelineController = TimelineControllerMock()
        timelineController.sendAnimatedImageUrlThumbnailURLImageInfoCaptionInReplyToEventIDClosure = { [weak self] url, _, imageInfo, caption, inReplyToEventID in
            if let image = try? Data(contentsOf: url) {
                self?.sent = SentImage(url: url, image: image, imageInfo: imageInfo, caption: caption, inReplyToEventID: inReplyToEventID)
            }
            return .success(())
        }
        sender = GifSender(provider: provider, timelineController: timelineController)
    }
    
    @Test
    func sendsTheProvidersFileAsAnAnimatedImageThroughTheSendQueue() async throws {
        try await sender.send(item, caption: "So true", inReplyToEventID: "$reply").get()
        
        #expect(provider.dataFromReceivedInvocations.map(\.absoluteString).sorted() == ["https://static.klipy.com/md.jpg", "https://static.klipy.com/md.webp"])
        let sent = try #require(sent)
        #expect(sent.caption == "So true")
        #expect(sent.inReplyToEventID == "$reply")
        #expect(sent.url.lastPathComponent == "Hello")
        #expect(sent.image == Self.webp)
        #expect(sent.imageInfo.isAnimated == true)
        #expect(sent.imageInfo.mimetype == "image/webp")
        #expect(sent.imageInfo.width == 1)
        #expect(sent.imageInfo.height == 1)
        #expect(sent.imageInfo.size == UInt64(Self.webp.count))
        #expect(sent.imageInfo.thumbnailInfo?.mimetype == "image/jpeg")
        #expect(sent.imageInfo.thumbnailInfo?.width == 4)
        #expect(sent.imageInfo.thumbnailInfo?.height == 3)
        #expect(sent.imageInfo.blurhash != nil)
        #expect(!FileManager.default.fileExists(atPath: sent.url.deletingLastPathComponent().path(percentEncoded: false)))
    }
    
    @Test
    func failedDownloadSendsNothing() async {
        provider.dataFromClosure = { _ in .failure(.network(URLError(.notConnectedToInternet))) }
        
        guard case .failure(.downloadFailed) = await sender.send(item, caption: nil, inReplyToEventID: nil) else {
            Issue.record("Expected the download to fail")
            return
        }
        #expect(!timelineController.sendAnimatedImageUrlThumbnailURLImageInfoCaptionInReplyToEventIDCalled)
    }
    
    @Test
    func itemWithoutARenditionIsRefused() async {
        guard case .failure(.noRendition) = await sender.send(GifItem(id: "x", title: "", renditions: [:]), caption: nil, inReplyToEventID: nil) else {
            Issue.record("Expected no rendition")
            return
        }
        #expect(!provider.dataFromCalled)
    }
    
    @Test
    func filenameIsTheTitleMadeSafe() {
        #expect(GifSender.filename(for: "Hello") == "Hello")
        #expect(GifSender.filename(for: "Yes/No: maybe") == "Yes No  maybe")
        #expect(GifSender.filename(for: "  ") == "GIF")
        #expect(GifSender.filename(for: "../etc") == "GIF")
        #expect(GifSender.filename(for: String(repeating: "a", count: 300)).count == 100)
    }
    
    private static func jpeg(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private struct SentImage {
    let url: URL
    let image: Data
    let imageInfo: ImageInfo
    let caption: String?
    let inReplyToEventID: String?
}
