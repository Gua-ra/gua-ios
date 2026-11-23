//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

@testable import ElementX
import Foundation
import Testing

@MainActor
final class TimelineStickerSheetViewModelTests {
    private let image = StickerImage(url: "mxc://gua.global/wave", body: "Waving cat", info: StickerImageInfo(width: 160, height: 160, mimetype: "image/webp", size: 900))
    
    private var clientProxy: ClientProxyMock!
    private var library: StickerLibrarySetting!
    private var packClient: StickerPackClientMock!
    
    init() {
        clientProxy = ClientProxyMock(.init())
        library = StickerLibrarySetting(clientProxy: clientProxy, cache: InMemoryAccountDataCache())
        packClient = StickerPackClientMock()
        packClient.packEventsRoomIDReturnValue = .success([])
    }
    
    @Test
    func savingAddsTheStickerToMyStickers() async throws {
        let viewModel = makeViewModel()
        #expect(!viewModel.state.isSaved)
        
        viewModel.context.send(viewAction: .save)
        try await waitUntil { viewModel.state.isSaved }
        
        #expect(library.libraryPublisher.value.images.map(\.image.url) == [image.url])
        #expect(library.libraryPublisher.value.images.first?.image.body == "Waving cat")
    }
    
    @Test
    func favouriteToggles() async throws {
        let viewModel = makeViewModel()
        
        viewModel.context.send(viewAction: .toggleFavourite)
        try await waitUntil { viewModel.state.isFavourite }
        viewModel.context.send(viewAction: .toggleFavourite)
        try await waitUntil { !viewModel.state.isFavourite }
        
        #expect(library.libraryPublisher.value.favourites.isEmpty)
    }
    
    @Test
    func showsThePackItCameFrom() async throws {
        packClient.packEventsRoomIDReturnValue = .success([StickerPackStateEvent(eventType: StickerPack.stableEventType,
                                                                                 stateKey: "cats",
                                                                                 content: .object(["images": .object(["wave": image.json]),
                                                                                                   "pack": .object(["display_name": .string("Cats")])]))])
        let viewModel = makeViewModel()
        
        try await waitUntil { viewModel.state.packName != nil }
        
        #expect(viewModel.state.packName == "Cats")
    }
    
    @Test
    func failedWriteShowsAnError() async throws {
        clientProxy.setAccountDataTypeContentReturnValue = .failure(.forbiddenAccess)
        let viewModel = makeViewModel()
        
        viewModel.context.send(viewAction: .toggleFavourite)
        try await waitUntil { viewModel.state.bindings.alertInfo != nil }
        
        #expect(viewModel.state.bindings.alertInfo?.id == .updateFailed)
        #expect(!viewModel.state.isFavourite)
    }
    
    @Test
    func timelineStickerKeepsItsInfo() throws {
        let source = try MediaSourceProxy(url: "mxc://gua.global/dance", mimeType: "image/gif")
        let item = StickerRoomTimelineItem(id: .randomEvent,
                                           body: "Dance",
                                           timestamp: .mock,
                                           isOutgoing: false,
                                           isEditable: false,
                                           canBeRepliedTo: true,
                                           sender: .init(id: "@bob:gua.global"),
                                           imageInfo: ImageInfoProxy(source: source, width: 160, height: 120, mimeType: "image/gif", fileSize: 300, isAnimated: true),
                                           blurhash: nil)
        
        let image = TimelineStickerSheetViewModel.image(for: item)
        
        #expect(image.json == .object(["body": .string("Dance"),
                                       "info": .object(["h": .int(120), "is_animated": .bool(true), "mimetype": .string("image/gif"), "size": .int(300), "w": .int(160)]),
                                       "url": .string("mxc://gua.global/dance")]))
    }
    
    private func makeViewModel() -> TimelineStickerSheetViewModel {
        TimelineStickerSheetViewModel(image: image,
                                      library: library,
                                      packClient: packClient,
                                      roomProxy: JoinedRoomProxyMock(.init(name: "Family")),
                                      mediaProvider: MediaProviderMock(.init()))
    }
    
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
