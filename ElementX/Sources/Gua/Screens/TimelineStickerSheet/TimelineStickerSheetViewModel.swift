//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation

typealias TimelineStickerSheetViewModelType = StateStoreViewModelV2<TimelineStickerSheetViewState, TimelineStickerSheetViewAction>

final class TimelineStickerSheetViewModel: TimelineStickerSheetViewModelType, Identifiable {
    private let library: StickerLibrarySetting
    
    let id = UUID()
    
    init(image: StickerImage,
         library: StickerLibrarySetting,
         packClient: StickerPackClientProtocol,
         roomProxy: JoinedRoomProxyProtocol,
         mediaProvider: MediaProviderProtocol?) {
        self.library = library
        super.init(initialViewState: TimelineStickerSheetViewState(image: image), mediaProvider: mediaProvider)
        
        library.libraryPublisher
            .sink { [weak self] library in
                self?.state.isFavourite = library.isFavourite(url: image.url)
                self?.state.isSaved = library.images.contains { $0.image.url == image.url }
            }
            .store(in: &cancellables)
        
        Task { [weak self] in
            guard case .success(let events) = await packClient.packEvents(roomID: roomProxy.id) else { return }
            let roomName = roomProxy.infoPublisher.value.displayName ?? ""
            self?.state.packName = events
                .map { StickerPack(eventType: $0.eventType, stateKey: $0.stateKey, content: $0.content, roomName: roomName, roomAvatarURL: nil) }
                .first { $0.stickers.contains { $0.image.url == image.url } }?
                .displayName
        }
    }
    
    static func image(for item: StickerRoomTimelineItem) -> StickerImage {
        let info = item.imageInfo
        return StickerImage(url: info.source.url.absoluteString,
                            body: item.body,
                            info: StickerImageInfo(width: info.size.map { Int($0.width) },
                                                   height: info.size.map { Int($0.height) },
                                                   mimetype: info.mimeType,
                                                   size: info.fileSize.map { Int($0) },
                                                   isAnimated: info.isAnimated ? true : nil))
    }
    
    override func process(viewAction: TimelineStickerSheetViewAction) {
        switch viewAction {
        case .save:
            Task {
                if case .failure(let error) = await library.add(state.image) {
                    showAlert(for: error)
                }
            }
        case .toggleFavourite:
            Task {
                let result = if state.isFavourite {
                    await library.unfavourite(url: state.image.url)
                } else {
                    await library.favourite(state.image)
                }
                if case .failure(let error) = result {
                    showAlert(for: error)
                }
            }
        }
    }
    
    private func showAlert(for error: StickerLibraryUpdateError) {
        state.bindings.alertInfo = switch error {
        case .limitReached:
            AlertInfo(id: .limitReached, title: UntranslatedL10n.guaStickerLimitError(StickerLibrary.maxImages))
        case .writeFailed:
            AlertInfo(id: .updateFailed, title: L10n.errorUnknown)
        }
    }
}
