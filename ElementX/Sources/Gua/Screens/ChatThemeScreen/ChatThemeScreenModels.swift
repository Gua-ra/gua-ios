//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI

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

struct ChatThemePreviewDraft: Equatable, Identifiable {
    let id = UUID()
    /// What saving writes, which is no theme for the Default and Classic tiles.
    let theme: ChatTheme
    /// What the preview draws, which for the Default tile is the user's default.
    let shownTheme: ChatTheme
    /// Nil follows the app's appearance.
    var previewColorScheme: ColorScheme?
}

struct ChatThemeScreenViewState: BindableState {
    enum Mode {
        case chat
        case defaultTheme
    }

    let mode: Mode
    /// The chat's own theme in a chat, else the user's default.
    var current: ChatTheme
    var defaultTheme: ChatTheme
    var canChange: Bool
    /// A public chat that hides media doesn't show its photo, here either.
    var isPhotoHidden: Bool
    var bindings = ChatThemeScreenViewStateBindings()

    let sections = ChatThemeGallerySection.all

    /// The first Featured tile follows the user's default in a chat, and is the stock look for the default itself.
    var firstTileTheme: ChatTheme {
        mode == .chat ? defaultTheme : .stock
    }

    var firstTileName: String {
        mode == .chat ? UntranslatedL10n.guaChatBackgroundValueDefault : UntranslatedL10n.guaChatThemeClassic
    }

    var shownWallpaper: ChatBackground {
        isPhotoHidden && current.wallpaper.photo != nil ? .none : current.wallpaper
    }

    var setThemeTitle: String {
        mode == .chat ? UntranslatedL10n.guaChatThemeActionSetTheme : UntranslatedL10n.guaChatThemeActionSetDefault
    }

    var note: String {
        mode == .chat ? UntranslatedL10n.guaChatThemeSharedNote : UntranslatedL10n.guaChatThemeDefaultNote
    }

    func canSave(_ theme: ChatTheme) -> Bool {
        canChange && theme != current
    }
}

struct ChatThemeScreenViewStateBindings {
    var themePreview: ChatThemePreviewDraft?
    /// The bubble picker shows while this holds its choice.
    var bubbleChoice: ChatBubbleColor?
    var isWallpaperPickerPresented = false
    var wallpaperPreview: ChatThemePreviewDraft?
    var photoDraft: ChatBackgroundPhotoDraft?
    var alertInfo: AlertInfo<ChatThemeScreenAlertType>?
}

extension ChatThemeScreenViewStateBindings {
    var isScreenTopmost: Bool {
        themePreview == nil && bubbleChoice == nil && !isWallpaperPickerPresented
    }

    var isWallpaperPickerTopmost: Bool {
        wallpaperPreview == nil && photoDraft == nil
    }
}

enum ChatThemeScreenAlertType: Hashable {
    case failed
    case photoTooLarge
}

enum ChatThemeScreenViewAction {
    case selectTheme(ChatTheme)
    case selectFirstTile
    case presentBubblePicker
    case chooseBubble(ChatBubbleColor)
    case setBubble
    case presentWallpaperPicker
    case selectWallpaper(ChatBackground)
    case photoPicked(load: () async -> Data?)
    case setPhotoDim(Double)
    case movePhoto(alignX: Double, alignY: Double)
    case discardPhoto
    case setPhoto
    /// Applies to whichever preview is open.
    case setPreviewColorScheme(ColorScheme)
    case cancelPreview
    case savePreview
}
