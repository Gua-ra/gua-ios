//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

/// Images drawn on the device, so previews never touch the network or bundled media.
enum StickerPreviewImages {
    static let colors: [UIColor] = [.systemOrange, .systemTeal, .systemPink, .systemGreen, .systemPurple, .systemYellow]
    
    static let photo: CGImage = draw(size: CGSize(width: 600, height: 400)) { context in
        UIColor.systemTeal.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        UIColor.systemGreen.setFill()
        context.cgContext.fillEllipse(in: CGRect(x: -100, y: 260, width: 800, height: 300))
        UIColor.systemOrange.setFill()
        context.cgContext.fillEllipse(in: CGRect(x: 220, y: 110, width: 160, height: 160))
    }
    
    static func sticker(_ index: Int) -> CGImage {
        draw(size: CGSize(width: 256, height: 256)) { _ in
            colors[index % colors.count].setFill()
            UIBezierPath(roundedRect: CGRect(x: 32, y: 32, width: 192, height: 192), cornerRadius: CGFloat(24 + index * 12 % 72)).fill()
        }
    }
    
    static func pngData(_ index: Int) -> Data {
        UIImage(cgImage: sticker(index)).pngData() ?? Data()
    }
    
    private static func draw(size: CGSize, _ drawing: (UIGraphicsImageRendererContext) -> Void) -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        guard let image = UIGraphicsImageRenderer(size: size, format: format).image(actions: drawing).cgImage else {
            fatalError("Failed drawing a preview image")
        }
        return image
    }
}

enum ExpressionPanelPreviewFixtures {
    static func viewModel(tab: ExpressionPanelTab, withContent: Bool = true, gifContent: GifPanelContent = .loaded) -> ExpressionPanelViewModel {
        let appSettings = AppSettings.volatile()
        appSettings.guaExpressionPanelShowsGifs = tab == .gifs
        let directories = sessionDirectories(withContent: withContent)
        let gifProvider = Self.gifProvider(isAvailable: gifContent != .unavailable)
        
        let packClient = StickerPackClientMock()
        packClient.packEventsRoomIDReturnValue = .success([])
        
        let viewModel = ExpressionPanelViewModel(stickersAndGifs: StickersAndGifs(clientProxy: ClientProxyMock(.init()),
                                                                                  appSettings: appSettings,
                                                                                  sessionDirectories: directories,
                                                                                  gifProvider: gifProvider,
                                                                                  packClient: packClient),
                                                 roomProxy: JoinedRoomProxyMock(.init(name: "Family")),
                                                 stickerSender: StickerSenderMock(),
                                                 gifSender: GifSenderMock(),
                                                 cutoutService: StickerCutoutServiceMock(),
                                                 appSettings: appSettings,
                                                 threadRootEventID: nil,
                                                 latestEventID: { nil },
                                                 mediaProvider: mediaProvider)
        if gifContent != .unavailable {
            viewModel.state.gifContent = gifContent
            viewModel.state.gifItems = gifContent == .loaded && withContent ? gifItems : []
        }
        return viewModel
    }
    
    static func gifPreviewViewModel() -> ExpressionPanelViewModel {
        let viewModel = viewModel(tab: .gifs)
        viewModel.state.bindings.gifPreview = GifPreview(item: gifItems[0], caption: "So true")
        return viewModel
    }
    
    static let gifItems: [GifItem] = (0..<6).map { index in
        let height = [180, 240, 120, 200, 160, 220][index]
        let file = GifFile(url: URL(string: "https://static.klipy.com/preview/\(index).webp") ?? .homeDirectory, width: 220, height: height, size: 1000)
        let still = GifFile(url: URL(string: "https://static.klipy.com/preview/\(index).jpg") ?? .homeDirectory, width: 220, height: height, size: 100)
        return GifItem(id: "preview-\(index)", title: "Preview \(index)", renditions: [.sm: GifRendition(name: .sm, animated: file, still: still)]) // l10n-ignore
    }
    
    static let mediaProvider: MediaProviderProtocol = {
        let mediaProvider = MediaProviderMock(.init())
        let image: (MediaSourceProxy?) -> UIImage = { source in
            let index = Int(source?.url.lastPathComponent.filter(\.isNumber) ?? "") ?? 0
            return UIImage(cgImage: StickerPreviewImages.sticker(index))
        }
        mediaProvider.imageFromSourceSizeClosure = { source, _ in image(source) }
        mediaProvider.loadImageRetryingOnReconnectionSizeClosure = { source, _ in
            let loaded = image(source)
            return Task { loaded }
        }
        return mediaProvider
    }()
    
    private static func gifProvider(isAvailable: Bool) -> GifProviderMock {
        let provider = GifProviderMock()
        provider.underlyingId = KlipyGifProvider.providerID
        provider.underlyingIsAvailable = isAvailable
        provider.dataFromClosure = { url in
            .success(StickerPreviewImages.pngData(Int(url.deletingPathExtension().lastPathComponent) ?? 0))
        }
        return provider
    }
    
    private static func sessionDirectories(withContent: Bool) -> SessionDirectories {
        let base = FileManager.default.temporaryDirectory.appending(path: "expression-panel-preview-\(UUID().uuidString)")
        let directories = SessionDirectories(dataDirectory: base.appending(path: "data"), cacheDirectory: base.appending(path: "cache"))
        try? FileManager.default.createDirectory(at: directories.dataDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: directories.cacheDirectory, withIntermediateDirectories: true)
        guard withContent else { return directories }
        
        let info = StickerImageInfo(width: 256, height: 256, mimetype: "image/png", size: 1000)
        var library = StickerLibrary(contentJSON: nil)
        for index in 0..<5 {
            _ = try? library.add(StickerImage(url: "mxc://gua.global/mine\(index)", body: "Mine \(index)", info: info), now: Int64(index))
        }
        library.favourite(StickerImage(url: "mxc://gua.global/mine2", body: "Mine 2", info: info))
        try? Data(library.contentJSON.utf8).write(to: directories.cacheDirectory.appending(path: "account-data-\(StickerLibrary.accountDataType).json"))
        
        let recents = (0..<3).map { StickerImage(url: "mxc://gua.global/recent\($0 + 3)", body: "Recent \($0)", info: info) }
        try? JSONEncoder().encode(recents).write(to: directories.dataDirectory.appending(path: "gua-recent-stickers.json"))
        return directories
    }
}
