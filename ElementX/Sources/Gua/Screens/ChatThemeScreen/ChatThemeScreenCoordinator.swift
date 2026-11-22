//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI

enum ChatThemeScreenMode {
    case chat(JoinedRoomProxyProtocol)
    case defaultTheme
}

struct ChatThemeScreenCoordinatorParameters {
    let mode: ChatThemeScreenMode
    let userSession: UserSessionProtocol
    let userIndicatorController: UserIndicatorControllerProtocol
}

final class ChatThemeScreenCoordinator: CoordinatorProtocol {
    private let viewModel: ChatThemeScreenViewModelProtocol

    init(parameters: ChatThemeScreenCoordinatorParameters) {
        viewModel = ChatThemeScreenViewModel(mode: parameters.mode,
                                             clientProxy: parameters.userSession.clientProxy,
                                             chatBackgroundService: parameters.userSession.chatBackgroundService,
                                             userIndicatorController: parameters.userIndicatorController,
                                             mediaProvider: parameters.userSession.mediaProvider)
    }

    func toPresentable() -> AnyView {
        AnyView(ChatThemeScreen(context: viewModel.context))
    }
}
