//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import SwiftUI

typealias ExpressionPanelViewModelType = StateStoreViewModelV2<ExpressionPanelViewState, ExpressionPanelViewAction>

final class ExpressionPanelViewModel: ExpressionPanelViewModelType, ExpressionPanelViewModelProtocol {
    private let stickersAndGifs: StickersAndGifs
    private let roomProxy: JoinedRoomProxyProtocol
    private let stickerSender: StickerSenderProtocol
    private let gifSender: GifSenderProtocol
    private let cutoutService: StickerCutoutServiceProtocol
    private let appSettings: AppSettings
    private let threadRootEventID: String?
    private let latestEventID: () -> String?
    private let searchDebounce: Duration
    
    private var composerMode: ComposerMode = .default
    private var packs: [StickerPack] = []
    private var hasLoadedPacks = false
    private var gifBrowseSource: GifPanelSource = .trending
    private var gifTask: Task<Void, Never>?
    private var gifSearchTask: Task<Void, Never>?
    
    private let actionsSubject: PassthroughSubject<ExpressionPanelViewModelAction, Never> = .init()
    var actions: AnyPublisher<ExpressionPanelViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    private var gifProvider: GifProvider {
        stickersAndGifs.gifProvider
    }
    
    init(stickersAndGifs: StickersAndGifs,
         roomProxy: JoinedRoomProxyProtocol,
         stickerSender: StickerSenderProtocol,
         gifSender: GifSenderProtocol,
         cutoutService: StickerCutoutServiceProtocol,
         appSettings: AppSettings,
         threadRootEventID: String?,
         latestEventID: @escaping () -> String?,
         mediaProvider: MediaProviderProtocol?,
         searchDebounce: Duration = .milliseconds(300)) {
        self.stickersAndGifs = stickersAndGifs
        self.roomProxy = roomProxy
        self.stickerSender = stickerSender
        self.gifSender = gifSender
        self.cutoutService = cutoutService
        self.appSettings = appSettings
        self.threadRootEventID = threadRootEventID
        self.latestEventID = latestEventID
        self.searchDebounce = searchDebounce
        
        super.init(initialViewState: ExpressionPanelViewState(gifProvider: stickersAndGifs.gifProvider,
                                                              tab: appSettings.guaExpressionPanelShowsGifs ? .gifs : .stickers,
                                                              gifContent: stickersAndGifs.gifProvider.isAvailable ? .loading : .unavailable),
                   mediaProvider: mediaProvider)
        
        stickersAndGifs.library.libraryPublisher
            .sink { [weak self] _ in self?.rebuildStickerSections() }
            .store(in: &cancellables)
        stickersAndGifs.recentStickers.itemsPublisher
            .sink { [weak self] _ in self?.rebuildStickerSections() }
            .store(in: &cancellables)
        stickersAndGifs.gifFavourites.favouritesPublisher
            .sink { [weak self] favourites in
                guard let self else { return }
                state.gifFavouriteIDs = Set(favourites.ids(provider: gifProvider.id))
            }
            .store(in: &cancellables)
    }
    
    static func makeIfEnabled(userSession: UserSessionProtocol,
                              roomProxy: JoinedRoomProxyProtocol,
                              timelineController: TimelineControllerProtocol) -> ExpressionPanelViewModel? {
        guard userSession.userSettings.app.guaStickersAndGifsEnabled else { return nil }
        
        let stickersAndGifs = userSession.stickersAndGifs
        return ExpressionPanelViewModel(stickersAndGifs: stickersAndGifs,
                                        roomProxy: roomProxy,
                                        stickerSender: StickerSender(roomProxy: roomProxy, clientProxy: userSession.clientProxy),
                                        gifSender: GifSender(provider: stickersAndGifs.gifProvider, timelineController: timelineController),
                                        cutoutService: StickerCutoutService(),
                                        appSettings: userSession.userSettings.app,
                                        threadRootEventID: timelineController.timelineKind.threadRootEventID,
                                        latestEventID: {
                                            timelineController.timelineItems.reversed().lazy
                                                .compactMap { ($0 as? EventBasedTimelineItemProtocol)?.id.eventID }
                                                .first
                                        },
                                        mediaProvider: userSession.mediaProvider)
    }
    
    override func process(viewAction: ExpressionPanelViewAction) {
        switch viewAction {
        case .setPresentation(let presentation):
            setPresentation(presentation)
        case .keyboardHeightChanged(let height):
            state.keyboardHeight = height
        case .selectTab(let tab):
            selectTab(tab)
        case .updateSearch(let text):
            updateSearch(text, debounced: true)
        case .selectWord(let word):
            updateSearch(word.text, debounced: false)
        case .sendSticker(let item):
            send(item.image, tileID: item.id)
        case .favouriteSticker(let image):
            Task { await updateLibrary { await $0.favourite(image) } }
        case .unfavouriteSticker(let url):
            Task { await updateLibrary { await $0.unfavourite(url: url) } }
        case .removeRecentSticker(let url):
            stickersAndGifs.recentStickers.remove(id: url)
        case .deleteSticker(let shortcode):
            confirmDelete(shortcode: shortcode)
        case .saveSticker(let image):
            Task { await save(image) }
        case .createSticker:
            state.bindings.isPhotoPickerPresented = true
        case .pickedPhoto(let data):
            openEditor(with: data)
        case .selectGifSource(let source):
            selectGifSource(source)
        case .loadMoreGifs:
            loadMoreGifs()
        case .retryGifs:
            loadGifs(reset: true)
        case .openGif(let item):
            state.bindings.gifPreview = GifPreview(item: item)
        case .toggleGifFavourite(let item):
            Task { await toggleFavourite(item) }
        case .sendGif:
            Task { await sendGif() }
        }
    }
    
    func process(composerAction: ComposerToolbarViewModelAction) {
        switch composerAction {
        case .composerModeChanged(let mode):
            composerMode = mode
        case .sendStickerGlyphs(let glyphs):
            sendGlyphs(glyphs)
        case .sendPastedSticker(let data):
            sendPastedSticker(data)
        default:
            break
        }
    }
    
    private func sendGlyphs(_ glyphs: [StickerGlyph]) {
        Task {
            for glyph in glyphs {
                guard let image = await uploadedImage(for: glyph) else {
                    state.bindings.alertInfo = sendFailedAlert
                    return
                }
                await sendNow(image, tileID: nil)
            }
        }
    }
    
    private func sendPastedSticker(_ data: Data) {
        Task {
            guard let file = StickerGlyph.largestImage(in: data).flatMap(StickerImageEncoder.stickerFile(from:)),
                  case .success(let image) = await stickerSender.upload(file, body: StickerMessageContent.defaultBody) else {
                state.bindings.alertInfo = sendFailedAlert
                return
            }
            await sendNow(image, tileID: nil)
        }
    }
    
    private func setPresentation(_ presentation: ExpressionPanelPresentation) {
        state.presentation = presentation
        guard presentation != .hidden else { return }
        
        if !hasLoadedPacks {
            hasLoadedPacks = true
            Task { await loadPacks() }
        }
        if state.tab == .gifs, state.gifItems.isEmpty, state.gifContent != .unavailable {
            applyGifSearch()
        }
    }
    
    private func selectTab(_ tab: ExpressionPanelTab) {
        state.tab = tab
        appSettings.guaExpressionPanelShowsGifs = tab == .gifs
        if tab == .gifs {
            applyGifSearch()
        }
    }
    
    private func updateSearch(_ text: String, debounced: Bool) {
        state.searchText = text
        rebuildStickerSections()
        
        guard state.tab == .gifs else { return }
        gifSearchTask?.cancel()
        guard debounced else {
            applyGifSearch()
            return
        }
        gifSearchTask = Task { [weak self, searchDebounce] in
            try? await Task.sleep(for: searchDebounce)
            guard !Task.isCancelled else { return }
            self?.applyGifSearch()
        }
    }
    
    private var stickerRelation: StickerRelation? {
        let replyEventID = composerMode.replyEventID
        if let threadRootEventID {
            return .thread(rootEventID: threadRootEventID, latestEventID: replyEventID ?? latestEventID() ?? threadRootEventID)
        }
        return replyEventID.map { .reply(eventID: $0) }
    }
    
    private func rebuildStickerSections() {
        let library = stickersAndGifs.library.libraryPublisher.value
        let query = state.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        func items(_ section: StickerPanelSection.ID, _ entries: [(image: StickerImage, shortcode: String?)]) -> [StickerPanelItem] {
            entries
                .filter { Self.matches(query, image: $0.image, shortcode: $0.shortcode) }
                .map { StickerPanelItem(section: section, image: $0.image, shortcode: $0.shortcode, isFavourite: library.isFavourite(url: $0.image.url)) }
        }
        
        let recent = StickerPanelSection(id: .recent,
                                         title: UntranslatedL10n.guaExpressionRecent,
                                         iconURL: nil,
                                         items: items(.recent, stickersAndGifs.recentStickers.itemsPublisher.value.map { ($0, nil) }))
        let favourites = StickerPanelSection(id: .favourites,
                                             title: UntranslatedL10n.guaExpressionFavourites,
                                             iconURL: nil,
                                             items: items(.favourites, library.favourites.map { ($0, nil) }))
        let mine = StickerPanelSection(id: .mine,
                                       title: UntranslatedL10n.guaStickersMine,
                                       iconURL: library.images.first?.image.url,
                                       items: items(.mine, library.images.map { ($0.image, $0.shortcode) }))
        let packSections = packs.map { pack in
            StickerPanelSection(id: .pack(pack.id),
                                title: pack.displayName,
                                iconURL: pack.avatarURL,
                                items: items(.pack(pack.id), pack.stickers.map { ($0.image, $0.shortcode) }))
        }
        
        state.stickerSections = [recent] + ([favourites, mine] + packSections).filter { !$0.items.isEmpty }
    }
    
    static func matches(_ query: String, image: StickerImage, shortcode: String?) -> Bool {
        guard !query.isEmpty else { return true }
        return [image.body, shortcode].compactMap { $0 }.contains { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
    
    private func loadPacks() async {
        guard case .success(let events) = await stickersAndGifs.packClient.packEvents(roomID: roomProxy.id) else { return }
        let info = roomProxy.infoPublisher.value
        packs = events.map { event in
            StickerPack(eventType: event.eventType,
                        stateKey: event.stateKey,
                        content: event.content,
                        roomName: info.displayName ?? "",
                        roomAvatarURL: info.avatarURL?.absoluteString)
        }
        .filter { !$0.stickers.isEmpty }
        rebuildStickerSections()
    }
    
    private func send(_ image: StickerImage, tileID: String?) {
        if let tileID {
            guard !state.sendingStickerIDs.contains(tileID) else { return }
            state.sendingStickerIDs.insert(tileID)
        }
        Task { await sendNow(image, tileID: tileID) }
    }
    
    private func sendNow(_ image: StickerImage, tileID: String?) async {
        let relation = stickerRelation
        let answersReply = composerMode.replyEventID != nil
        let result = await stickerSender.send(image.essentials, relation: relation)
        if let tileID {
            state.sendingStickerIDs.remove(tileID)
        }
        
        switch result {
        case .success:
            stickersAndGifs.recentStickers.add(image.essentials)
            if answersReply {
                actionsSubject.send(.didSendReply)
            }
        case .failure:
            state.bindings.alertInfo = AlertInfo(id: .stickerSendFailed,
                                                 title: UntranslatedL10n.guaStickerSendError,
                                                 primaryButton: .init(title: L10n.actionCancel, role: .cancel, action: nil),
                                                 secondaryButton: .init(title: L10n.actionTryAgain) { [weak self] in
                                                     self?.send(image, tileID: tileID)
                                                 })
        }
    }
    
    private func uploadedImage(for glyph: StickerGlyph) async -> StickerImage? {
        if let image = stickersAndGifs.glyphCache.image(forContentIdentifier: glyph.contentIdentifier) {
            return image
        }
        guard let file = glyph.stickerFile(), case .success(let image) = await stickerSender.upload(file, body: glyph.body) else {
            return nil
        }
        stickersAndGifs.glyphCache.store(image, forContentIdentifier: glyph.contentIdentifier)
        return image
    }
    
    private func updateLibrary(_ update: (StickerLibrarySetting) async -> Result<Void, StickerLibraryUpdateError>) async {
        if case .failure(let error) = await update(stickersAndGifs.library) {
            state.bindings.alertInfo = alert(error)
        }
    }
    
    private func save(_ image: StickerImage) async {
        if case .failure(let error) = await stickersAndGifs.library.add(image) {
            state.bindings.alertInfo = alert(error)
        }
    }
    
    private func confirmDelete(shortcode: String) {
        state.bindings.alertInfo = AlertInfo(id: .deleteSticker,
                                             title: UntranslatedL10n.guaStickerDeleteTitle,
                                             primaryButton: .init(title: L10n.actionCancel, role: .cancel, action: nil),
                                             secondaryButton: .init(title: L10n.actionDelete, role: .destructive) { [weak self] in
                                                 Task { await self?.updateLibrary { await $0.delete(shortcode: shortcode) } }
                                             })
    }
    
    private func openEditor(with data: Data) {
        guard let photo = StickerEditorScreenViewModel.photo(from: data) else { return }
        
        let editor = StickerEditorScreenViewModel(photo: photo, cutoutService: cutoutService, appSettings: appSettings) { [weak self] file, body, send in
            await self?.saveCreatedSticker(file, body: body, send: send) ?? .failure(.failed)
        }
        editor.actions
            .sink { [weak self] action in
                switch action {
                case .dismiss:
                    self?.state.bindings.stickerEditor = nil
                }
            }
            .store(in: &cancellables)
        state.bindings.stickerEditor = editor
    }
    
    private func saveCreatedSticker(_ file: StickerFile, body: String, send: Bool) async -> Result<Void, StickerEditorError> {
        guard stickersAndGifs.library.libraryPublisher.value.images.count < StickerLibrary.maxImages else {
            return .failure(.limitReached)
        }
        guard case .success(let image) = await stickerSender.upload(file, body: body) else {
            return .failure(.failed)
        }
        
        switch await stickersAndGifs.library.add(image) {
        case .success(let item):
            if send {
                self.send(item.image, tileID: nil)
            }
            return .success(())
        case .failure(.limitReached):
            return .failure(.limitReached)
        case .failure(.writeFailed):
            return .failure(.failed)
        }
    }
    
    private func selectGifSource(_ source: GifPanelSource) {
        gifSearchTask?.cancel()
        if case .search = source {
            state.gifSource = source
        } else {
            gifBrowseSource = source
            state.searchText = ""
            rebuildStickerSections()
            state.gifSource = source
        }
        loadGifs(reset: true)
    }
    
    private func applyGifSearch() {
        let query = state.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = query.isEmpty ? gifBrowseSource : .search(query)
        guard source != state.gifSource || state.gifItems.isEmpty || state.gifContent == .failed else { return }
        state.gifSource = source
        loadGifs(reset: true)
    }
    
    private func loadMoreGifs() {
        guard state.gifContent == .loaded, state.gifHasNextPage, gifTask == nil else { return }
        loadGifs(reset: false)
    }
    
    private func loadGifs(reset: Bool) {
        guard gifProvider.isAvailable else {
            state.gifContent = .unavailable
            return
        }
        
        gifTask?.cancel()
        let source = state.gifSource
        let page = reset ? 1 : state.gifPage + 1
        if reset {
            state.gifContent = .loading
            state.gifItems = []
            state.gifHasNextPage = false
        }
        
        gifTask = Task { [weak self] in
            guard let self else { return }
            let result = await fetchGifs(source, page: page)
            guard !Task.isCancelled else { return }
            gifTask = nil
            
            switch result {
            case .success(let gifPage):
                state.gifItems = reset ? gifPage.items : state.gifItems + gifPage.items
                state.gifPage = gifPage.page
                state.gifHasNextPage = gifPage.hasNext
                state.gifContent = .loaded
            case .failure(.cancelled):
                break
            case .failure:
                if reset {
                    state.gifContent = .failed
                } else {
                    state.gifHasNextPage = false
                }
            }
        }
    }
    
    private func fetchGifs(_ source: GifPanelSource, page: Int) async -> Result<GifPage, GifProviderError> {
        switch source {
        case .trending:
            return await gifProvider.trending(page: page)
        case .search(let query):
            return await gifProvider.search(query, page: page)
        case .recent:
            return await items(ids: stickersAndGifs.recentGifs.itemsPublisher.value)
        case .favourites:
            return await items(ids: stickersAndGifs.gifFavourites.favouritesPublisher.value.ids(provider: gifProvider.id))
        }
    }
    
    /// Recents and favourites keep this device's order.
    private func items(ids: [String]) async -> Result<GifPage, GifProviderError> {
        await gifProvider.items(ids: ids).map { items in
            let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return GifPage(items: ids.compactMap { byID[$0] }, page: 1, hasNext: false)
        }
    }
    
    private func toggleFavourite(_ item: GifItem) async {
        let favourites = stickersAndGifs.gifFavourites
        let result = if state.gifFavouriteIDs.contains(item.id) {
            await favourites.unfavourite(id: item.id, provider: gifProvider.id)
        } else {
            await favourites.favourite(id: item.id, provider: gifProvider.id)
        }
        if case .failure = result {
            state.bindings.alertInfo = AlertInfo(id: .updateFailed, title: L10n.errorUnknown)
        }
    }
    
    private func sendGif() async {
        guard var preview = state.bindings.gifPreview, !preview.isSending else { return }
        preview.isSending = true
        state.bindings.gifPreview = preview
        
        let caption = preview.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let replyEventID = composerMode.replyEventID
        let result = await gifSender.send(preview.item, caption: caption.isEmpty ? nil : caption, inReplyToEventID: replyEventID)
        
        switch result {
        case .success:
            stickersAndGifs.recentGifs.add(preview.item.id)
            if replyEventID != nil {
                actionsSubject.send(.didSendReply)
            }
            state.bindings.gifPreview = nil
        case .failure:
            state.bindings.gifPreview?.isSending = false
            state.bindings.alertInfo = AlertInfo(id: .gifSendFailed, title: UntranslatedL10n.guaGifsLoadError)
        }
    }
    
    private func alert(_ error: StickerLibraryUpdateError) -> AlertInfo<ExpressionPanelAlert> {
        switch error {
        case .limitReached:
            AlertInfo(id: .limitReached, title: UntranslatedL10n.guaStickerLimitError(StickerLibrary.maxImages))
        case .writeFailed:
            AlertInfo(id: .updateFailed, title: L10n.errorUnknown)
        }
    }
    
    private var sendFailedAlert: AlertInfo<ExpressionPanelAlert> {
        AlertInfo(id: .stickerSendFailed, title: UntranslatedL10n.guaStickerSendError)
    }
}
