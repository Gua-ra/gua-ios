//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

enum TimelineStickerSheetViewAction {
    case save
    case toggleFavourite
}

enum TimelineStickerSheetAlert: Hashable {
    case limitReached
    case updateFailed
}

struct TimelineStickerSheetViewState: BindableState {
    let image: StickerImage
    var isFavourite = false
    var isSaved = false
    var packName: String?
    
    var bindings = TimelineStickerSheetViewStateBindings()
}

struct TimelineStickerSheetViewStateBindings {
    var alertInfo: AlertInfo<TimelineStickerSheetAlert>?
}
