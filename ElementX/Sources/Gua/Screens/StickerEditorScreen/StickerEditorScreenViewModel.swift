//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import SwiftUI

typealias StickerEditorScreenViewModelType = StateStoreViewModelV2<StickerEditorScreenViewState, StickerEditorScreenViewAction>

final class StickerEditorScreenViewModel: StickerEditorScreenViewModelType {
    static let maxPhotoSide = 1024
    
    private let appSettings: AppSettings
    private let saveAction: StickerEditorSaveAction
    private var subjectLayer: CGImage?
    
    private let actionsSubject: PassthroughSubject<StickerEditorScreenViewModelAction, Never> = .init()
    var actions: AnyPublisher<StickerEditorScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    let id = UUID()
    
    init(photo: CGImage, cutoutService: StickerCutoutServiceProtocol, appSettings: AppSettings, saveAction: @escaping StickerEditorSaveAction) {
        self.appSettings = appSettings
        self.saveAction = saveAction
        super.init(initialViewState: StickerEditorScreenViewState(photo: photo, showsNote: !appSettings.guaStickerCreatorNoteShown))
        renderPreview()
        
        Task { [weak self] in
            let cutout = await cutoutService.cutout(of: photo)
            self?.applyCutout(cutout)
        }
    }
    
    static func photo(from data: Data) -> CGImage? {
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(1, CGFloat(maxPhotoSide) / max(image.size.width * image.scale, image.size.height * image.scale, 1))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: (image.size.width * image.scale * scale).rounded(), height: (image.size.height * image.scale * scale).rounded())
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }
    
    override func process(viewAction: StickerEditorScreenViewAction) {
        switch viewAction {
        case .setCutOut(let isEnabled):
            state.isCutOutEnabled = isEnabled && state.canCutOut
            updateSubjectLayer()
        case .setText(let text):
            state.text = text
            renderPreview()
        case .setFraming(let scale, let offset):
            state.scale = min(max(scale, 0.25), 6)
            state.offset = offset
            renderPreview()
        case .tapCanvas(let point):
            toggleSubject(at: point)
        case .send:
            Task { await finish(send: true) }
        case .save:
            Task { await finish(send: false) }
        case .cancel:
            actionsSubject.send(.dismiss)
        }
    }
    
    func makeStickerFile() -> StickerFile? {
        state.preview.flatMap(StickerImageEncoder.stickerFile(from:))
    }
    
    private func applyCutout(_ cutout: StickerCutout?) {
        state.isFindingSubjects = false
        guard let cutout else { return }
        state.cutout = cutout
        state.selectedSubjects = IndexSet(cutout.subjectMasks.indices)
        state.isCutOutEnabled = true
        updateSubjectLayer()
    }
    
    private func toggleSubject(at canvasPoint: CGPoint) {
        guard state.isCutOutEnabled, let cutout = state.cutout,
              let point = StickerCanvas.imagePoint(forCanvasPoint: canvasPoint,
                                                   imageSize: CGSize(width: cutout.image.width, height: cutout.image.height),
                                                   scale: state.scale,
                                                   offset: state.offset),
              let subject = cutout.subject(at: point) else {
            return
        }
        if state.selectedSubjects.contains(subject) {
            state.selectedSubjects.remove(subject)
        } else {
            state.selectedSubjects.insert(subject)
        }
        updateSubjectLayer()
    }
    
    private func updateSubjectLayer() {
        if state.isCutOutEnabled, let cutout = state.cutout {
            subjectLayer = cutout.maskedImage(subjects: state.selectedSubjects)
        } else {
            subjectLayer = nil
        }
        renderPreview()
    }
    
    private func renderPreview() {
        state.preview = StickerCanvas.render(subjectLayer ?? state.canvasImage,
                                             outlined: subjectLayer != nil,
                                             scale: state.scale,
                                             offset: state.offset,
                                             text: state.text)
    }
    
    private func finish(send: Bool) async {
        guard !state.isSaving else { return }
        guard let file = makeStickerFile() else {
            state.bindings.alertInfo = alert(.failed)
            return
        }
        
        state.isSaving = true
        let text = state.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await saveAction(file, text.isEmpty ? StickerMessageContent.defaultBody : text, send)
        state.isSaving = false
        
        switch result {
        case .success:
            appSettings.guaStickerCreatorNoteShown = true
            actionsSubject.send(.dismiss)
        case .failure(.limitReached):
            state.bindings.alertInfo = alert(.limitReached)
        case .failure(.failed):
            state.bindings.alertInfo = alert(.failed)
        }
    }
    
    private func alert(_ alert: StickerEditorAlert) -> AlertInfo<StickerEditorAlert> {
        switch alert {
        case .limitReached:
            AlertInfo(id: alert, title: UntranslatedL10n.guaStickerLimitError(StickerLibrary.maxImages))
        case .failed:
            AlertInfo(id: alert, title: UntranslatedL10n.guaStickerSendError)
        }
    }
}

extension StickerEditorScreenViewModel: Identifiable { }
