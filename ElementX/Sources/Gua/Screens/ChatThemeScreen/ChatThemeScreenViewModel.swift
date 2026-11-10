//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

typealias ChatThemeScreenViewModelType = StateStoreViewModelV2<ChatThemeScreenViewState, ChatThemeScreenViewAction>

class ChatThemeScreenViewModel: ChatThemeScreenViewModelType, ChatThemeScreenViewModelProtocol {
    private let mode: ChatThemeScreenMode
    private let clientProxy: ClientProxyProtocol
    private let chatBackgroundService: ChatBackgroundServiceProtocol
    private let userIndicatorController: UserIndicatorControllerProtocol
    
    private let indicatorID = "ChatThemeScreen-Progress"
    
    init(mode: ChatThemeScreenMode,
         clientProxy: ClientProxyProtocol,
         chatBackgroundService: ChatBackgroundServiceProtocol,
         userIndicatorController: UserIndicatorControllerProtocol,
         mediaProvider: MediaProviderProtocol?) {
        self.mode = mode
        self.clientProxy = clientProxy
        self.chatBackgroundService = chatBackgroundService
        self.userIndicatorController = userIndicatorController
        
        let currentPublisher: CurrentValuePublisher<ChatTheme, Never>
        let initialState: ChatThemeScreenViewState
        switch mode {
        case .chat(let roomProxy):
            currentPublisher = chatBackgroundService.themePublisher(roomID: roomProxy.id)
            initialState = .init(mode: .chat,
                                 current: currentPublisher.value,
                                 defaultTheme: chatBackgroundService.defaultThemePublisher.value,
                                 canChange: Self.canChange(roomProxy.infoPublisher.value.powerLevels),
                                 isPhotoHidden: Self.isPhotoHidden(clientProxy.timelineMediaVisibilityPublisher.value,
                                                                   roomInfo: roomProxy.infoPublisher.value))
        case .defaultTheme:
            currentPublisher = chatBackgroundService.defaultThemePublisher
            initialState = .init(mode: .defaultTheme,
                                 current: currentPublisher.value,
                                 defaultTheme: currentPublisher.value,
                                 canChange: true,
                                 isPhotoHidden: false)
        }
        super.init(initialViewState: initialState, mediaProvider: mediaProvider)
        
        currentPublisher
            .weakAssign(to: \.state.current, on: self)
            .store(in: &cancellables)
        
        chatBackgroundService.defaultThemePublisher
            .weakAssign(to: \.state.defaultTheme, on: self)
            .store(in: &cancellables)
        
        if case .chat(let roomProxy) = mode {
            roomProxy.infoPublisher
                .map { Self.canChange($0.powerLevels) }
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .weakAssign(to: \.state.canChange, on: self)
                .store(in: &cancellables)
            
            clientProxy.timelineMediaVisibilityPublisher
                .combineLatest(roomProxy.infoPublisher)
                .map { Self.isPhotoHidden($0, roomInfo: $1) }
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .weakAssign(to: \.state.isPhotoHidden, on: self)
                .store(in: &cancellables)
        }
    }
    
    override func process(viewAction: ChatThemeScreenViewAction) {
        switch viewAction {
        case .selectTheme(let theme):
            state.bindings.themePreview = ChatThemePreviewDraft(theme: theme, shownTheme: theme)
        case .selectFirstTile:
            state.bindings.themePreview = ChatThemePreviewDraft(theme: .stock, shownTheme: state.shownTheme(saving: .stock))
        case .presentBubblePicker:
            state.bindings.bubbleChoice = state.baseTheme.bubble
        case .chooseBubble(let bubble):
            state.bindings.bubbleChoice = bubble
        case .setBubble:
            guard let bubble = state.bindings.bubbleChoice else { return }
            let theme = ChatTheme(wallpaper: state.baseTheme.wallpaper, bubble: bubble)
            guard state.canSavePickerChoice(theme) else { return }
            Task { await save(theme) }
        case .presentWallpaperPicker:
            state.bindings.isWallpaperPickerPresented = true
        case .selectWallpaper(let wallpaper):
            let theme = ChatTheme(wallpaper: wallpaper, bubble: state.baseTheme.bubble)
            state.bindings.wallpaperPreview = ChatThemePreviewDraft(theme: theme, shownTheme: state.shownTheme(saving: theme), isPickerChoice: true)
        case .photoPicked(let load):
            Task { await preparePhoto(load: load) }
        case .setPhotoDim(let dim):
            state.bindings.photoDraft?.dim = dim
            // Dim only shows in dark mode.
            state.bindings.photoDraft?.previewColorScheme = .dark
        case .movePhoto(let alignX, let alignY):
            state.bindings.photoDraft?.alignX = alignX.clamped(to: 0...1)
            state.bindings.photoDraft?.alignY = alignY.clamped(to: 0...1)
        case .discardPhoto:
            state.bindings.photoDraft = nil
        case .setPhoto:
            guard let draft = state.bindings.photoDraft else { return }
            Task { await setPhoto(draft) }
        case .setPreviewColorScheme(let colorScheme):
            if state.bindings.photoDraft != nil {
                state.bindings.photoDraft?.previewColorScheme = colorScheme
            } else if state.bindings.wallpaperPreview != nil {
                state.bindings.wallpaperPreview?.previewColorScheme = colorScheme
            } else {
                state.bindings.themePreview?.previewColorScheme = colorScheme
            }
        case .cancelPreview:
            if state.bindings.wallpaperPreview != nil {
                state.bindings.wallpaperPreview = nil
            } else {
                state.bindings.themePreview = nil
            }
        case .savePreview:
            guard let draft = state.bindings.wallpaperPreview ?? state.bindings.themePreview, state.canSave(draft) else { return }
            Task { await save(draft.theme) }
        }
    }
    
    private static func canChange(_ powerLevels: RoomPowerLevelsProxyProtocol?) -> Bool {
        powerLevels?.canOwnUser(sendStateEvent: .guaChatBackground) ?? false
    }
    
    /// The chat-side half of `ChatTheme.effective`, with an unknown join rule counted as public.
    private static func isPhotoHidden(_ visibility: TimelineMediaVisibility, roomInfo: RoomInfoProxyProtocol) -> Bool {
        visibility != .always && !(roomInfo.isPrivate ?? false)
    }
    
    private func preparePhoto(load: () async -> Data?) async {
        showProgress(title: L10n.commonLoading)
        defer { hideProgress() }
        
        guard let data = await load() else {
            state.bindings.alertInfo = .init(id: .failed, title: UntranslatedL10n.guaChatBackgroundErrorGeneric)
            return
        }
        
        let processed = await Task.detached(priority: .userInitiated) {
            Result { try ChatBackgroundImageProcessor.process(data) }
        }.value
        
        guard case .success(let upload) = processed, let image = UIImage(data: upload.data) else {
            state.bindings.alertInfo = .init(id: .failed, title: UntranslatedL10n.guaChatBackgroundErrorGeneric)
            return
        }
        
        if case .success(let maxUploadSize) = await clientProxy.maxMediaUploadSize, upload.data.count > maxUploadSize {
            state.bindings.alertInfo = .init(id: .photoTooLarge, title: UntranslatedL10n.guaChatBackgroundErrorTooLarge)
            return
        }
        
        state.bindings.photoDraft = ChatBackgroundPhotoDraft(upload: upload, image: image)
    }
    
    private func setPhoto(_ draft: ChatBackgroundPhotoDraft) async {
        showProgress(title: UntranslatedL10n.guaChatThemeProgress)
        defer { hideProgress() }
        
        let upload = draft.upload
        guard case .success(let url) = await clientProxy.uploadMedia(data: upload.data, mimeType: ChatBackgroundPhotoUpload.mimetype) else {
            await handleFailure()
            return
        }
        
        let photo = ChatBackground.Photo(url: url,
                                         mimetype: ChatBackgroundPhotoUpload.mimetype,
                                         width: upload.width,
                                         height: upload.height,
                                         size: upload.data.count,
                                         blurhash: upload.blurhash,
                                         dim: draft.dim,
                                         alignX: draft.alignX,
                                         alignY: draft.alignY)
        await send(ChatTheme(wallpaper: .photo(photo), bubble: state.baseTheme.bubble))
    }
    
    private func save(_ theme: ChatTheme) async {
        showProgress(title: UntranslatedL10n.guaChatThemeProgress)
        defer { hideProgress() }
        await send(theme)
    }
    
    private func send(_ theme: ChatTheme) async {
        let hasFailed = switch mode {
        case .chat(let roomProxy):
            await chatBackgroundService.set(theme, roomProxy: roomProxy).isFailure
        case .defaultTheme:
            await chatBackgroundService.setDefaultTheme(theme).isFailure
        }
        
        guard !hasFailed else {
            await handleFailure()
            return
        }
        state.bindings.themePreview = nil
        state.bindings.wallpaperPreview = nil
        state.bindings.photoDraft = nil
        state.bindings.bubbleChoice = nil
        state.bindings.isWallpaperPickerPresented = false
    }
    
    /// A refusal in a chat can mean the permissions changed, so they are read again.
    private func handleFailure() async {
        state.bindings.alertInfo = .init(id: .failed, title: UntranslatedL10n.guaChatBackgroundErrorGeneric)
        if case .chat(let roomProxy) = mode {
            state.canChange = Self.canChange(roomProxy.infoPublisher.value.powerLevels)
        }
    }
    
    private func showProgress(title: String) {
        userIndicatorController.submitIndicator(UserIndicator(id: indicatorID,
                                                              type: .modal(progress: .indeterminate, interactiveDismissDisabled: true, allowsInteraction: false),
                                                              title: title,
                                                              persistent: true))
    }
    
    private func hideProgress() {
        userIndicatorController.retractIndicatorWithId(indicatorID)
    }
}
