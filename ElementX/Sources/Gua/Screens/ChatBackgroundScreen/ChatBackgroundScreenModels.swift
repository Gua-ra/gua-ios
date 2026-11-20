//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI

enum ChatBackgroundScreenViewModelAction {
    case dismiss
}

struct ChatBackgroundPhotoDraft: Equatable, Identifiable {
    let id = UUID()
    let upload: ChatBackgroundPhotoUpload
    let image: UIImage
    var dim = ChatBackground.Photo.defaultDim
    var alignX = ChatBackground.Photo.defaultAlign
    var alignY = ChatBackground.Photo.defaultAlign
    /// Nil follows the app's appearance.
    var previewColorScheme: ColorScheme?

    static func == (lhs: ChatBackgroundPhotoDraft, rhs: ChatBackgroundPhotoDraft) -> Bool {
        lhs.id == rhs.id && lhs.dim == rhs.dim && lhs.alignX == rhs.alignX && lhs.alignY == rhs.alignY && lhs.previewColorScheme == rhs.previewColorScheme
    }
}

struct ChatBackgroundScreenViewState: BindableState {
    var current: ChatBackground
    /// Nil until a preset is picked, which leaves the current background selected.
    var pickedBackground: ChatBackground?
    var canChange: Bool
    var isMediaHidden: Bool
    var bindings = ChatBackgroundScreenViewStateBindings()

    var selection: ChatBackground {
        pickedBackground ?? current
    }

    var previewBackground: ChatBackground {
        isMediaHidden && selection.photo != nil ? .none : selection
    }

    var selectedPreset: ChatBackgroundPreset? {
        guard case .preset(let preset) = selection else { return nil }
        return preset
    }

    var canSet: Bool {
        canChange && selection != current
    }

    var canRemove: Bool {
        canChange && !current.isNone
    }
}

struct ChatBackgroundScreenViewStateBindings {
    var photoDraft: ChatBackgroundPhotoDraft?
    var alertInfo: AlertInfo<ChatBackgroundScreenAlertType>?
}

enum ChatBackgroundScreenAlertType: Hashable {
    case failed
    case photoTooLarge
}

enum ChatBackgroundScreenViewAction {
    case selectPreset(ChatBackgroundPreset)
    case photoPicked(load: () async -> Data?)
    case setPhotoDim(Double)
    case movePhoto(alignX: Double, alignY: Double)
    case setPreviewColorScheme(ColorScheme)
    case discardPhoto
    case apply
    case remove
}
