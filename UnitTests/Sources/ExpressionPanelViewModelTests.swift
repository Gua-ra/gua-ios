//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
@testable import ElementX
import Foundation
import ImageIO
import Testing

@MainActor
final class ExpressionPanelViewModelTests {
    private let info = StickerImageInfo(width: 256, height: 256, mimetype: "image/png", size: 1000)
    
    private let directory: URL
    private var appSettings: AppSettings!
    private var clientProxy: ClientProxyMock!
    private var gifProvider: GifProviderMock!
    private var packClient: StickerPackClientMock!
    private var stickerSender: StickerSenderMock!
    private var gifSender: GifSenderMock!
    private var stickersAndGifs: StickersAndGifs!
    private var viewModel: ExpressionPanelViewModel!
    private var actions: [ExpressionPanelViewModelAction] = []
    private var cancellables = Set<AnyCancellable>()
    
    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "ExpressionPanelViewModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appending(path: "data"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appending(path: "cache"), withIntermediateDirectories: true)
        appSettings = AppSettings.volatile()
        clientProxy = ClientProxyMock(.init())
        
        gifProvider = GifProviderMock()
        gifProvider.underlyingId = KlipyGifProvider.providerID
        gifProvider.underlyingIsAvailable = true
        gifProvider.trendingPageReturnValue = .success(GifPage(items: [gif("trending")], page: 1, hasNext: false))
        gifProvider.searchPageClosure = { [weak self] query, page in
            .success(GifPage(items: [self?.gif(query) ?? .init(id: query, title: query, renditions: [:])], page: page, hasNext: false))
        }
        
        packClient = StickerPackClientMock()
        packClient.packEventsRoomIDReturnValue = .success([])
        stickerSender = StickerSenderMock()
        stickerSender.sendRelationReturnValue = .success("$sticker")
        gifSender = GifSenderMock()
        gifSender.sendCaptionInReplyToEventIDReturnValue = .success(())
    }
    
    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
    
    @Test
    func firstOpenShowsStickersAndTheLastTabIsRemembered() {
        makeViewModel()
        #expect(viewModel.state.tab == .stickers)
        
        viewModel.context.send(viewAction: .selectTab(.gifs))
        makeViewModel()
        
        #expect(viewModel.state.tab == .gifs)
    }
    
    @Test
    func sectionsAreRecentFavouritesMineThenChatPacks() async throws {
        var library = StickerLibrary(contentJSON: nil)
        try library.add(sticker("mine"), now: 1)
        try Data(library.contentJSON.utf8).write(to: directory.appending(path: "cache/account-data-global.gua.stickers.json"))
        packClient.packEventsRoomIDReturnValue = .success([StickerPackStateEvent(eventType: StickerPack.stableEventType,
                                                                                 stateKey: "cats",
                                                                                 content: .object(["images": .object(["wave": sticker("wave").json])]))])
        makeViewModel()
        
        #expect(viewModel.state.stickerSections.map(\.id) == [.recent, .mine])
        
        viewModel.context.send(viewAction: .setPresentation(.compact))
        try await waitUntil { self.viewModel.state.stickerSections.count == 3 }
        viewModel.context.send(viewAction: .favouriteSticker(sticker("mine")))
        try await waitUntil { self.viewModel.state.stickerSections.count == 4 }
        
        #expect(viewModel.state.stickerSections.map(\.id) == [.recent, .favourites, .mine, .pack("m.room.image_pack|cats")])
        #expect(viewModel.state.stickerSections.last?.title == "Family")
    }
    
    @Test
    func stickerSearchMatchesBodiesAndShortcodesWithoutCaseOrAccents() {
        #expect(ExpressionPanelViewModel.matches("ELEFANTE", image: StickerImage(url: "mxc://a/b", body: "Elefante dançando", info: nil), shortcode: nil))
        #expect(ExpressionPanelViewModel.matches("dancando", image: StickerImage(url: "mxc://a/b", body: "Elefante dançando", info: nil), shortcode: nil))
        #expect(ExpressionPanelViewModel.matches("wav", image: StickerImage(url: "mxc://a/b", body: nil, info: nil), shortcode: "wave"))
        #expect(!ExpressionPanelViewModel.matches("cat", image: StickerImage(url: "mxc://a/b", body: "Dog", info: nil), shortcode: "dog"))
    }
    
    @Test
    func searchFiltersEverySection() throws {
        let recents = [sticker("cat", body: "Gato"), sticker("dog", body: "Cão")]
        try JSONEncoder().encode(recents).write(to: directory.appending(path: "data/gua-recent-stickers.json"))
        makeViewModel()
        
        viewModel.context.send(viewAction: .updateSearch("cao"))
        
        #expect(viewModel.state.stickerSections.first?.items.map(\.image.url) == ["mxc://gua.global/dog"])
        #expect(!gifProvider.searchPageCalled)
    }
    
    @Test
    func gifSearchWaitsForTypingToStop() async throws {
        appSettings.guaExpressionPanelShowsGifs = true
        makeViewModel(searchDebounce: .milliseconds(100))
        
        for text in ["h", "ha", "hap", "happy"] {
            viewModel.context.send(viewAction: .updateSearch(text))
        }
        try await waitUntil { self.gifProvider.searchPageCalled }
        try await Task.sleep(for: .milliseconds(200))
        
        #expect(gifProvider.searchPageCallsCount == 1)
        #expect(gifProvider.searchPageReceivedArguments?.query == "happy")
        #expect(viewModel.state.gifItems.map(\.id) == ["happy"])
    }
    
    @Test
    func aNewSearchCancelsTheOneRunning() async throws {
        appSettings.guaExpressionPanelShowsGifs = true
        gifProvider.searchPageClosure = { [weak self] query, page in
            if query == "slow" {
                try? await Task.sleep(for: .milliseconds(300))
            }
            return .success(GifPage(items: [self?.gif(query) ?? .init(id: query, title: query, renditions: [:])], page: page, hasNext: false))
        }
        makeViewModel(searchDebounce: .milliseconds(10))
        
        viewModel.context.send(viewAction: .updateSearch("slow"))
        try await waitUntil { self.gifProvider.searchPageCallsCount == 1 }
        viewModel.context.send(viewAction: .updateSearch("fast"))
        try await waitUntil { self.viewModel.state.gifItems.map(\.id) == ["fast"] }
        try await Task.sleep(for: .milliseconds(400))
        
        #expect(viewModel.state.gifItems.map(\.id) == ["fast"])
    }
    
    @Test
    func gifsPageInTheProviderOrder() async throws {
        appSettings.guaExpressionPanelShowsGifs = true
        gifProvider.trendingPageClosure = { [weak self] page in
            guard let self else { return .failure(.cancelled) }
            return page == 1
                ? .success(GifPage(items: [gif("b"), gif("a")], page: 1, hasNext: true))
                : .success(GifPage(items: [gif("d"), gif("c")], page: 2, hasNext: false))
        }
        makeViewModel()
        
        viewModel.context.send(viewAction: .setPresentation(.compact))
        try await waitUntil { self.viewModel.state.gifContent == .loaded }
        viewModel.context.send(viewAction: .loadMoreGifs)
        try await waitUntil { self.viewModel.state.gifItems.count == 4 }
        
        #expect(viewModel.state.gifItems.map(\.id) == ["b", "a", "d", "c"])
        #expect(!viewModel.state.gifHasNextPage)
        #expect(gifProvider.trendingPageReceivedInvocations == [1, 2])
    }
    
    @Test
    func withoutAKeyGifsAreUnavailable() {
        gifProvider.underlyingIsAvailable = false
        appSettings.guaExpressionPanelShowsGifs = true
        makeViewModel()
        
        viewModel.context.send(viewAction: .setPresentation(.compact))
        viewModel.context.send(viewAction: .updateSearch("hi"))
        
        #expect(viewModel.state.gifContent == .unavailable)
        #expect(!gifProvider.trendingPageCalled)
    }
    
    @Test
    func failedGifsCanBeRetried() async throws {
        appSettings.guaExpressionPanelShowsGifs = true
        gifProvider.trendingPageReturnValue = .failure(.server(status: 500))
        makeViewModel()
        
        viewModel.context.send(viewAction: .setPresentation(.compact))
        try await waitUntil { self.viewModel.state.gifContent == .failed }
        
        gifProvider.trendingPageReturnValue = .success(GifPage(items: [gif("ok")], page: 1, hasNext: false))
        viewModel.context.send(viewAction: .retryGifs)
        try await waitUntil { self.viewModel.state.gifContent == .loaded }
        
        #expect(viewModel.state.gifItems.map(\.id) == ["ok"])
    }
    
    @Test
    func recentGifsKeepThisDevicesOrder() async throws {
        appSettings.guaExpressionPanelShowsGifs = true
        try JSONEncoder().encode(["second", "first"]).write(to: directory.appending(path: "data/gua-recent-gifs.json"))
        gifProvider.itemsIdsReturnValue = .success([gif("first"), gif("second")])
        makeViewModel()
        
        viewModel.context.send(viewAction: .selectGifSource(.recent))
        try await waitUntil { self.viewModel.state.gifContent == .loaded }
        
        #expect(viewModel.state.gifItems.map(\.id) == ["second", "first"])
    }
    
    @Test
    func sentStickerAnswersTheReplyAndJoinsRecents() async throws {
        makeViewModel()
        viewModel.process(composerAction: .composerModeChanged(mode: .reply(eventID: "$reply", replyDetails: .loading(eventID: "$reply"), isThread: false)))
        let item = StickerPanelItem(section: .mine, image: sticker("cat").with(added: 4), shortcode: "s4", isFavourite: false)
        
        viewModel.context.send(viewAction: .sendSticker(item))
        try await waitUntil { !self.actions.isEmpty }
        
        #expect(stickerSender.sendRelationReceivedArguments?.relation == .reply(eventID: "$reply"))
        #expect(stickerSender.sendRelationReceivedArguments?.image == sticker("cat"))
        #expect(stickersAndGifs.recentStickers.itemsPublisher.value == [sticker("cat")])
        #expect(viewModel.state.sendingStickerIDs.isEmpty)
    }
    
    @Test
    func stickersInAThreadFallBackToItsLatestEvent() async throws {
        makeViewModel(threadRootEventID: "$root")
        
        viewModel.context.send(viewAction: .sendSticker(StickerPanelItem(section: .recent, image: sticker("cat"), shortcode: nil, isFavourite: false)))
        try await waitUntil { self.stickerSender.sendRelationCalled }
        
        #expect(stickerSender.sendRelationReceivedArguments?.relation == .thread(rootEventID: "$root", latestEventID: "$latest"))
    }
    
    @Test
    func failedStickerOffersARetry() async throws {
        stickerSender.sendRelationReturnValue = .failure(.sendFailed(.eventNotFound))
        makeViewModel()
        
        viewModel.context.send(viewAction: .sendSticker(StickerPanelItem(section: .recent, image: sticker("cat"), shortcode: nil, isFavourite: false)))
        try await waitUntil { self.viewModel.state.bindings.alertInfo != nil }
        
        #expect(viewModel.state.bindings.alertInfo?.id == .stickerSendFailed)
        #expect(stickersAndGifs.recentStickers.itemsPublisher.value.isEmpty)
        
        stickerSender.sendRelationReturnValue = .success("$sticker")
        viewModel.state.bindings.alertInfo?.secondaryButton?.action?()
        try await waitUntil { !self.stickersAndGifs.recentStickers.itemsPublisher.value.isEmpty }
        #expect(stickerSender.sendRelationCallsCount == 2)
    }
    
    @Test
    func longPressActionsUpdateTheLibraryAndRecents() async throws {
        try JSONEncoder().encode([sticker("cat")]).write(to: directory.appending(path: "data/gua-recent-stickers.json"))
        makeViewModel()
        
        viewModel.context.send(viewAction: .saveSticker(sticker("cat")))
        try await waitUntil { self.stickersAndGifs.library.libraryPublisher.value.images.count == 1 }
        viewModel.context.send(viewAction: .favouriteSticker(sticker("cat")))
        try await waitUntil { self.stickersAndGifs.library.libraryPublisher.value.isFavourite(url: "mxc://gua.global/cat") }
        viewModel.context.send(viewAction: .removeRecentSticker(url: "mxc://gua.global/cat"))
        
        #expect(stickersAndGifs.recentStickers.itemsPublisher.value.isEmpty)
        
        let shortcode = try #require(stickersAndGifs.library.libraryPublisher.value.images.first?.shortcode)
        viewModel.context.send(viewAction: .deleteSticker(shortcode: shortcode))
        #expect(viewModel.state.bindings.alertInfo?.id == .deleteSticker)
        viewModel.state.bindings.alertInfo?.secondaryButton?.action?()
        try await waitUntil { self.stickersAndGifs.library.libraryPublisher.value.images.isEmpty }
        
        #expect(!stickersAndGifs.library.libraryPublisher.value.isFavourite(url: "mxc://gua.global/cat"))
    }
    
    @Test
    func savingPastTheLimitShowsTheLimit() async throws {
        var library = StickerLibrary(contentJSON: nil)
        for index in 0..<StickerLibrary.maxImages {
            try library.add(sticker("s\(index)"), now: Int64(index))
        }
        try Data(library.contentJSON.utf8).write(to: directory.appending(path: "cache/account-data-global.gua.stickers.json"))
        makeViewModel()
        
        viewModel.context.send(viewAction: .saveSticker(sticker("cat")))
        try await waitUntil { self.viewModel.state.bindings.alertInfo != nil }
        
        #expect(viewModel.state.bindings.alertInfo?.id == .limitReached)
    }
    
    @Test
    func sentGifJoinsRecentsWithItsCaptionAndReply() async throws {
        makeViewModel()
        viewModel.process(composerAction: .composerModeChanged(mode: .reply(eventID: "$reply", replyDetails: .loading(eventID: "$reply"), isThread: false)))
        
        viewModel.context.send(viewAction: .openGif(gif("hello")))
        viewModel.context.gifPreview?.caption = "  Hi there "
        viewModel.context.send(viewAction: .sendGif)
        try await waitUntil { self.viewModel.state.bindings.gifPreview == nil }
        
        #expect(gifSender.sendCaptionInReplyToEventIDReceivedArguments?.caption == "Hi there")
        #expect(gifSender.sendCaptionInReplyToEventIDReceivedArguments?.inReplyToEventID == "$reply")
        #expect(stickersAndGifs.recentGifs.itemsPublisher.value == ["hello"])
    }
    
    @Test
    func longPressTogglesAGifFavourite() async throws {
        makeViewModel()
        
        viewModel.context.send(viewAction: .toggleGifFavourite(gif("hello")))
        try await waitUntil { self.viewModel.state.gifFavouriteIDs == ["hello"] }
        viewModel.context.send(viewAction: .toggleGifFavourite(gif("hello")))
        try await waitUntil { self.viewModel.state.gifFavouriteIDs.isEmpty }
    }
    
    @Test
    func glyphsUploadOncePerDevice() async throws {
        stickerSender.uploadBodyReturnValue = .success(sticker("glyph"))
        makeViewModel()
        let glyph = try StickerGlyph(imageContent: Self.imageData(), contentIdentifier: "genmoji-1", contentDescription: "Happy cat")
        
        viewModel.process(composerAction: .sendStickerGlyphs([glyph]))
        try await waitUntil { self.stickerSender.sendRelationCallsCount == 1 }
        viewModel.process(composerAction: .sendStickerGlyphs([glyph]))
        try await waitUntil { self.stickerSender.sendRelationCallsCount == 2 }
        
        #expect(stickerSender.uploadBodyCallsCount == 1)
        #expect(stickerSender.uploadBodyReceivedArguments?.body == "Happy cat")
    }
    
    @Test
    func theFlagDecidesWhetherThereIsAPanel() {
        let userSession = UserSessionMock(.init(userSettings: appSettings.userSettings(for: "@me:matrix.org"), stickersAndGifs: makeStickersAndGifs()))
        let timelineController = TimelineControllerMock(.init())
        
        appSettings.guaStickersAndGifsEnabled = false
        #expect(ExpressionPanelViewModel.makeIfEnabled(userSession: userSession, roomProxy: JoinedRoomProxyMock(.init()), timelineController: timelineController) == nil)
        
        appSettings.guaStickersAndGifsEnabled = true
        #expect(ExpressionPanelViewModel.makeIfEnabled(userSession: userSession, roomProxy: JoinedRoomProxyMock(.init()), timelineController: timelineController) != nil)
    }
    
    private func makeViewModel(threadRootEventID: String? = nil, searchDebounce: Duration = .milliseconds(10)) {
        stickersAndGifs = makeStickersAndGifs()
        viewModel = ExpressionPanelViewModel(stickersAndGifs: stickersAndGifs,
                                             roomProxy: JoinedRoomProxyMock(.init(name: "Family")),
                                             stickerSender: stickerSender,
                                             gifSender: gifSender,
                                             cutoutService: StickerCutoutServiceMock(),
                                             appSettings: appSettings,
                                             threadRootEventID: threadRootEventID,
                                             latestEventID: { "$latest" },
                                             mediaProvider: MediaProviderMock(.init()),
                                             searchDebounce: searchDebounce)
        viewModel.actions
            .sink { [weak self] in self?.actions.append($0) }
            .store(in: &cancellables)
    }
    
    private func makeStickersAndGifs() -> StickersAndGifs {
        StickersAndGifs(clientProxy: clientProxy,
                        appSettings: appSettings,
                        sessionDirectories: SessionDirectories(dataDirectory: directory.appending(path: "data"), cacheDirectory: directory.appending(path: "cache")),
                        gifProvider: gifProvider,
                        packClient: packClient)
    }
    
    private func sticker(_ name: String, body: String? = nil) -> StickerImage {
        StickerImage(url: "mxc://gua.global/\(name)", body: body ?? name, info: info)
    }
    
    private func gif(_ id: String) -> GifItem {
        let file = GifFile(url: URL(string: "https://static.klipy.com/\(id).webp") ?? .homeDirectory, width: 200, height: 100, size: 1000)
        let still = GifFile(url: URL(string: "https://static.klipy.com/\(id).jpg") ?? .homeDirectory, width: 200, height: 100, size: 100)
        return GifItem(id: id, title: id, renditions: [.sm: GifRendition(name: .sm, animated: file, still: still)])
    }
    
    private static func imageData() throws -> Data {
        let image = StickerPreviewImages.sticker(1)
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
    
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
