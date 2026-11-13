//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
@testable import ElementX
import Foundation
import MatrixRustSDK
import Testing
import WysiwygComposer

/// The panel's sends leave the composer's text as typed and only drop a reply they answered.
@MainActor
final class ExpressionPanelComposerTests {
    private let directory: URL
    private var composer: ComposerToolbarViewModel!
    private var panel: ExpressionPanelViewModel!
    private var stickerSender: StickerSenderMock!
    private var gifSender: GifSenderMock!
    private var cancellables = Set<AnyCancellable>()
    
    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "ExpressionPanelComposerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appending(path: "data"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appending(path: "cache"), withIntermediateDirectories: true)
        
        composer = ComposerToolbarViewModel(roomProxy: JoinedRoomProxyMock(.init()),
                                            wysiwygViewModel: WysiwygComposerViewModel(),
                                            completionSuggestionService: CompletionSuggestionServiceMock(configuration: .init()),
                                            mediaProvider: MediaProviderMock(.init()),
                                            mentionDisplayHelper: ComposerMentionDisplayHelper.mock,
                                            userSettings: UserSettings.mock(),
                                            analyticsService: AnalyticsServiceMock(.init()),
                                            composerDraftService: ComposerDraftServiceMock(.init()))
        composer.context.composerFormattingEnabled = false
        
        stickerSender = StickerSenderMock()
        stickerSender.sendRelationReturnValue = .success("$sticker")
        gifSender = GifSenderMock()
        gifSender.sendCaptionInReplyToEventIDReturnValue = .success(())
        let gifProvider = GifProviderMock()
        gifProvider.underlyingId = KlipyGifProvider.providerID
        gifProvider.underlyingIsAvailable = true
        let packClient = StickerPackClientMock()
        packClient.packEventsRoomIDReturnValue = .success([])
        let appSettings = AppSettings.volatile()
        
        panel = ExpressionPanelViewModel(stickersAndGifs: StickersAndGifs(clientProxy: ClientProxyMock(.init()),
                                                                          appSettings: appSettings,
                                                                          sessionDirectories: SessionDirectories(dataDirectory: directory.appending(path: "data"),
                                                                                                                 cacheDirectory: directory.appending(path: "cache")),
                                                                          gifProvider: gifProvider,
                                                                          packClient: packClient),
                                         roomProxy: JoinedRoomProxyMock(.init()),
                                         stickerSender: stickerSender,
                                         gifSender: gifSender,
                                         cutoutService: StickerCutoutServiceMock(),
                                         appSettings: appSettings,
                                         threadRootEventID: nil,
                                         latestEventID: { nil },
                                         mediaProvider: MediaProviderMock(.init()))
        
        // The same wiring as the room and thread coordinators.
        composer.actions
            .sink { [weak self] in self?.panel.process(composerAction: $0) }
            .store(in: &cancellables)
        panel.actions
            .sink { [weak self] action in
                switch action {
                case .didSendReply:
                    self?.composer.process(timelineAction: .setMode(mode: .default))
                }
            }
            .store(in: &cancellables)
    }
    
    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
    
    @Test
    func typedTextSurvivesAGifAndTheReplyIsDropped() async throws {
        typeAndReply()
        
        panel.context.send(viewAction: .openGif(gif))
        panel.context.send(viewAction: .sendGif)
        try await waitUntil { self.composer.state.composerMode == .default }
        
        #expect(gifSender.sendCaptionInReplyToEventIDReceivedArguments?.inReplyToEventID == "$reply")
        #expect(composer.context.plainComposerText.string == "Hello")
    }
    
    @Test
    func typedTextSurvivesAStickerAndTheReplyIsDropped() async throws {
        typeAndReply()
        
        panel.context.send(viewAction: .sendSticker(StickerPanelItem(section: .recent, image: sticker, shortcode: nil, isFavourite: false)))
        try await waitUntil { self.composer.state.composerMode == .default }
        
        #expect(stickerSender.sendRelationReceivedArguments?.relation == .reply(eventID: "$reply"))
        #expect(composer.context.plainComposerText.string == "Hello")
    }
    
    @Test
    func sendsWithoutAReplyLeaveTheComposerUntouched() async throws {
        composer.process(timelineAction: .setText(plainText: "Hello", htmlText: nil))
        let edit = ComposerMode.edit(originalEventOrTransactionID: .eventID("$edit"), type: .default)
        composer.process(timelineAction: .setMode(mode: edit))
        
        panel.context.send(viewAction: .sendSticker(StickerPanelItem(section: .recent, image: sticker, shortcode: nil, isFavourite: false)))
        panel.context.send(viewAction: .openGif(gif))
        panel.context.send(viewAction: .sendGif)
        try await waitUntil { self.stickerSender.sendRelationCalled && self.panel.state.bindings.gifPreview == nil }
        
        #expect(stickerSender.sendRelationReceivedArguments?.relation == nil)
        #expect(composer.state.composerMode == edit)
        #expect(composer.context.plainComposerText.string == "Hello")
    }
    
    @Test
    func panelGIFsSkipTheCallbackThatClearsTheComposer() async {
        let timelineProxy = TimelineProxyMock(.init(timelineItemProvider: makeItemProvider()))
        var sentReplyEventIDs: [String?] = []
        timelineProxy.sendImageUrlThumbnailURLImageInfoCaptionInReplyToEventIDRequestHandleClosure = { _, _, _, _, inReplyToEventID, _ in
            sentReplyEventIDs.append(inReplyToEventID)
            return .success(())
        }
        let controller = TimelineController(roomProxy: JoinedRoomProxyMock(.init()),
                                            timelineProxy: timelineProxy,
                                            initialFocussedEventID: nil,
                                            timelineItemFactory: RoomTimelineItemFactory(userID: "@alice:matrix.org",
                                                                                         attributedStringBuilder: AttributedStringBuilder(mentionBuilder: MentionBuilder()),
                                                                                         stateEventStringBuilder: RoomStateEventStringBuilder(userID: "@alice:matrix.org")),
                                            mediaProvider: MediaProviderMock(.init()),
                                            userSettings: .mock())
        var sentCallbacks = 0
        controller.callbacks
            .sink {
                if case .messageSentOrEdited = $0 {
                    sentCallbacks += 1
                }
            }
            .store(in: &cancellables)
        let info = ImageInfo(height: 1, width: 1, mimetype: "image/webp", size: 1, thumbnailInfo: nil, thumbnailSource: nil, blurhash: nil, isAnimated: true)
        
        _ = await controller.sendAnimatedImage(url: .homeDirectory, thumbnailURL: .homeDirectory, imageInfo: info, caption: nil, inReplyToEventID: "$reply")
        #expect(sentReplyEventIDs == ["$reply"])
        #expect(sentCallbacks == 0)
        
        _ = await controller.sendImage(url: .homeDirectory, thumbnailURL: .homeDirectory, imageInfo: info, caption: nil, inReplyToEventID: nil) { _ in }
        #expect(sentCallbacks == 1)
    }
    
    private var sticker: StickerImage {
        StickerImage(url: "mxc://gua.global/cat", body: "Cat", info: nil)
    }
    
    private var gif: GifItem {
        let file = GifFile(url: .homeDirectory, width: 200, height: 100, size: 1000)
        return GifItem(id: "hello", title: "Hello", renditions: [.sm: GifRendition(name: .sm, animated: file, still: file)])
    }
    
    private func typeAndReply() {
        composer.process(timelineAction: .setText(plainText: "Hello", htmlText: nil))
        composer.process(timelineAction: .setMode(mode: .reply(eventID: "$reply", replyDetails: .loading(eventID: "$reply"), isThread: false)))
    }
    
    private func makeItemProvider() -> TimelineItemProviderMock {
        let paginationState = TimelinePaginationState(backward: .idle, forward: .endReached)
        let provider = TimelineItemProviderMock()
        provider.kind = .live
        provider.itemProxies = []
        provider.paginationState = paginationState
        provider.membershipChangePublisher = PassthroughSubject().eraseToAnyPublisher()
        provider.updatePublisher = CurrentValueSubject<([TimelineItemProxy], TimelinePaginationState), Never>(([], paginationState)).eraseToAnyPublisher()
        return provider
    }
    
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
