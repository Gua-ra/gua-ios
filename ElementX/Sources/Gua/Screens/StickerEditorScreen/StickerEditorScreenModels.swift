//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

enum StickerEditorError: Error, Equatable {
    case limitReached
    case failed
}

typealias StickerEditorSaveAction = (_ file: StickerFile, _ body: String, _ send: Bool) async -> Result<Void, StickerEditorError>

enum StickerEditorScreenViewModelAction {
    case dismiss
}

enum StickerEditorScreenViewAction {
    case setCutOut(Bool)
    case setText(String)
    case setFraming(scale: CGFloat, offset: CGSize)
    case tapCanvas(CGPoint)
    case send
    case save
    case cancel
}

enum StickerEditorAlert: Hashable {
    case limitReached
    case failed
}

struct StickerEditorScreenViewState: BindableState {
    let photo: CGImage
    var cutout: StickerCutout?
    var isFindingSubjects = true
    var selectedSubjects = IndexSet()
    var isCutOutEnabled = false
    var text = ""
    var scale: CGFloat = 1
    var offset: CGSize = .zero
    var preview: CGImage?
    var showsNote: Bool
    var isSaving = false
    
    var bindings = StickerEditorScreenViewStateBindings()
    
    var canCutOut: Bool {
        cutout != nil
    }
    
    /// The photo the canvas shows, which is the one the cut-out's masks were made from.
    var canvasImage: CGImage {
        cutout?.image ?? photo
    }
}

struct StickerEditorScreenViewStateBindings {
    var alertInfo: AlertInfo<StickerEditorAlert>?
}
