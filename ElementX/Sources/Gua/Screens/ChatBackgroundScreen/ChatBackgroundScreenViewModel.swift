//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

typealias ChatBackgroundScreenViewModelType = StateStoreViewModelV2<ChatBackgroundScreenViewState, ChatBackgroundScreenViewAction>

class ChatBackgroundScreenViewModel: ChatBackgroundScreenViewModelType, ChatBackgroundScreenViewModelProtocol {
    private let roomProxy: JoinedRoomProxyProtocol
    private let clientProxy: ClientProxyProtocol
    private let chatBackgroundService: ChatBackgroundServiceProtocol
    private let userIndicatorController: UserIndicatorControllerProtocol

    private let indicatorID = "ChatBackgroundScreen-Progress"

    private let actionsSubject: PassthroughSubject<ChatBackgroundScreenViewModelAction, Never> = .init()
    var actionsPublisher: AnyPublisher<ChatBackgroundScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(roomProxy: JoinedRoomProxyProtocol,
         clientProxy: ClientProxyProtocol,
         chatBackgroundService: ChatBackgroundServiceProtocol,
         userIndicatorController: UserIndicatorControllerProtocol,
         mediaProvider: MediaProviderProtocol?) {
        self.roomProxy = roomProxy
        self.clientProxy = clientProxy
        self.chatBackgroundService = chatBackgroundService
        self.userIndicatorController = userIndicatorController

        let backgroundPublisher = chatBackgroundService.backgroundPublisher(roomID: roomProxy.id)
        super.init(initialViewState: .init(current: backgroundPublisher.value,
                                           canChange: Self.canChange(roomProxy.infoPublisher.value.powerLevels),
                                           isMediaHidden: Self.isMediaHidden(clientProxy.timelineMediaVisibilityPublisher.value,
                                                                             roomInfo: roomProxy.infoPublisher.value)),
                   mediaProvider: mediaProvider)

        backgroundPublisher
            .weakAssign(to: \.state.current, on: self)
            .store(in: &cancellables)

        roomProxy.infoPublisher
            .map { Self.canChange($0.powerLevels) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.state.canChange, on: self)
            .store(in: &cancellables)

        clientProxy.timelineMediaVisibilityPublisher
            .combineLatest(roomProxy.infoPublisher)
            .map { Self.isMediaHidden($0, roomInfo: $1) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.state.isMediaHidden, on: self)
            .store(in: &cancellables)
    }

    override func process(viewAction: ChatBackgroundScreenViewAction) {
        switch viewAction {
        case .selectPreset(let preset):
            state.pickedBackground = .preset(preset)
        case .photoPicked(let load):
            Task { await preparePhoto(load: load) }
        case .setPhotoDim(let dim):
            state.bindings.photoDraft?.dim = dim
            // Dim only shows in dark mode.
            state.bindings.photoDraft?.previewColorScheme = .dark
        case .movePhoto(let alignX, let alignY):
            state.bindings.photoDraft?.alignX = alignX.clamped(to: 0...1)
            state.bindings.photoDraft?.alignY = alignY.clamped(to: 0...1)
        case .setPreviewColorScheme(let colorScheme):
            state.bindings.photoDraft?.previewColorScheme = colorScheme
        case .discardPhoto:
            state.bindings.photoDraft = nil
        case .apply:
            if let draft = state.bindings.photoDraft {
                Task { await setPhoto(draft) }
            } else {
                Task { await set(state.selection, progressTitle: UntranslatedL10n.guaChatBackgroundProgress) }
            }
        case .remove:
            Task { await set(.none, progressTitle: UntranslatedL10n.guaChatBackgroundProgressRemove) }
        }
    }

    private static func canChange(_ powerLevels: RoomPowerLevelsProxyProtocol?) -> Bool {
        powerLevels?.canOwnUser(sendStateEvent: .guaChatBackground) ?? false
    }

    private static func isMediaHidden(_ visibility: TimelineMediaVisibility, roomInfo: RoomInfoProxyProtocol) -> Bool {
        switch visibility {
        case .always:
            false
        case .privateOnly:
            !(roomInfo.isPrivate ?? false)
        case .never:
            true
        }
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
        showProgress(title: UntranslatedL10n.guaChatBackgroundProgress)
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
        await send(.photo(photo))
    }

    private func set(_ background: ChatBackground, progressTitle: String) async {
        showProgress(title: progressTitle)
        defer { hideProgress() }
        await send(background)
    }

    private func send(_ background: ChatBackground) async {
        switch await chatBackgroundService.set(background, roomProxy: roomProxy) {
        case .success:
            state.bindings.photoDraft = nil
            actionsSubject.send(.dismiss)
        case .failure:
            await handleFailure()
        }
    }

    /// A refusal can mean the permissions changed, so they are read again.
    private func handleFailure() async {
        state.bindings.alertInfo = .init(id: .failed, title: UntranslatedL10n.guaChatBackgroundErrorGeneric)
        if case .success(let powerLevels) = await roomProxy.powerLevels() {
            state.canChange = Self.canChange(powerLevels)
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
