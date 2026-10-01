//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation

enum FindFriendsScreenViewModelAction {
    case startedChat(roomID: String)
    case showProfile(userID: String)
    case close
}

enum FindFriendsScreenPhase: Equatable {
    case loading
    case needsPermission
    case empty
    case loaded
    case error
}

struct FindFriendsScreenViewState: BindableState {
    var phase: FindFriendsScreenPhase = .loading
    var contacts: [DiscoveredContact] = []
    var errorMessage: String?
    var bindings = FindFriendsScreenViewStateBindings()

    var startingChatUserID: String?
}

struct FindFriendsScreenViewStateBindings {
    var alertInfo: AlertInfo<UUID>?
}

enum FindFriendsScreenViewAction {
    case retry
    case openSystemSettings
    case selectContact(DiscoveredContact)
    case showProfile(DiscoveredContact)
    case close
}
