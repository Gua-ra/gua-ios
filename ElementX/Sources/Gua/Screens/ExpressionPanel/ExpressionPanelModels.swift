//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

enum ExpressionPanelTab: Hashable {
    case gifs
    case stickers
}

enum ExpressionPanelPresentation: Equatable {
    case hidden
    case compact
    case expanded
}

enum ExpressionPanelViewModelAction {
    /// A send from the panel used the composer's reply. The composer's text stays as typed.
    case didSendReply
}

enum ExpressionPanelViewAction {
    case setPresentation(ExpressionPanelPresentation)
    case keyboardHeightChanged(CGFloat)
    case selectTab(ExpressionPanelTab)
    case updateSearch(String)
    case selectWord(ExpressionWord)
    
    case sendSticker(StickerPanelItem)
    case favouriteSticker(StickerImage)
    case unfavouriteSticker(url: String)
    case removeRecentSticker(url: String)
    case deleteSticker(shortcode: String)
    case saveSticker(StickerImage)
    case createSticker
    case pickedPhoto(Data)
    
    case selectGifSource(GifPanelSource)
    case loadMoreGifs
    case retryGifs
    case openGif(GifItem)
    case toggleGifFavourite(GifItem)
    case sendGif
}

enum ExpressionWord: CaseIterable, Hashable {
    case hi, haha, love, sad, wow, thumbsUp, celebrate, angry, dance
    
    static let chips: [ExpressionWord] = [.hi, .haha, .love, .sad, .wow]
    static let moods: [ExpressionWord] = [.haha, .love, .sad, .thumbsUp, .celebrate, .wow, .angry, .dance]
    
    var text: String {
        switch self {
        case .hi: UntranslatedL10n.guaExpressionWordHi
        case .haha: UntranslatedL10n.guaExpressionWordHaha
        case .love: UntranslatedL10n.guaExpressionWordLove
        case .sad: UntranslatedL10n.guaExpressionWordSad
        case .wow: UntranslatedL10n.guaExpressionWordWow
        case .thumbsUp: UntranslatedL10n.guaExpressionWordThumbsUp
        case .celebrate: UntranslatedL10n.guaExpressionWordCelebrate
        case .angry: UntranslatedL10n.guaExpressionWordAngry
        case .dance: UntranslatedL10n.guaExpressionWordDance
        }
    }
}

struct StickerPanelSection: Identifiable, Equatable {
    enum ID: Hashable {
        case recent
        case favourites
        case mine
        case pack(String)
    }
    
    let id: ID
    let title: String
    let iconURL: String?
    let items: [StickerPanelItem]
}

struct StickerPanelItem: Identifiable, Hashable {
    let section: StickerPanelSection.ID
    let image: StickerImage
    let shortcode: String?
    let isFavourite: Bool
    
    var id: String {
        "\(section)|\(shortcode ?? image.url)"
    }
    
    var accessibilityLabel: String {
        "\(L10n.commonSticker), \(image.body ?? shortcode ?? "")"
    }
}

enum GifPanelSource: Hashable {
    case recent
    case favourites
    case trending
    case search(String)
}

enum GifPanelContent: Equatable {
    case unavailable
    case loading
    case loaded
    case failed
}

struct GifPreview: Identifiable {
    let item: GifItem
    var caption = ""
    var isSending = false
    
    var id: String {
        item.id
    }
}

enum ExpressionPanelAlert: Hashable {
    case stickerSendFailed
    case deleteSticker
    case limitReached
    case updateFailed
    case gifSendFailed
}

struct ExpressionPanelViewState: BindableState {
    let gifProvider: GifProvider
    var presentation: ExpressionPanelPresentation = .hidden
    var keyboardHeight: CGFloat?
    var tab: ExpressionPanelTab
    var searchText = ""
    
    var stickerSections: [StickerPanelSection] = []
    var sendingStickerIDs: Set<String> = []
    
    var gifSource: GifPanelSource = .trending
    var gifContent: GifPanelContent
    var gifItems: [GifItem] = []
    var gifPage = 0
    var gifHasNextPage = false
    var gifFavouriteIDs: Set<String> = []
    
    var bindings = ExpressionPanelViewStateBindings()
    
    var searchPlaceholder: String {
        switch tab {
        case .gifs: "Search KLIPY" // l10n-ignore
        case .stickers: UntranslatedL10n.guaStickersSearchPlaceholder
        }
    }
}

struct ExpressionPanelViewStateBindings {
    var alertInfo: AlertInfo<ExpressionPanelAlert>?
    var gifPreview: GifPreview?
    var isPhotoPickerPresented = false
    var stickerEditor: StickerEditorScreenViewModel?
}
