//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

struct ChatBackgroundScreenCoordinatorParameters {
    let roomProxy: JoinedRoomProxyProtocol
    let userSession: UserSessionProtocol
    let userIndicatorController: UserIndicatorControllerProtocol
}

enum ChatBackgroundScreenCoordinatorAction {
    case dismiss
}

final class ChatBackgroundScreenCoordinator: CoordinatorProtocol {
    private let viewModel: ChatBackgroundScreenViewModelProtocol

    private var cancellables = Set<AnyCancellable>()

    private let actionsSubject: PassthroughSubject<ChatBackgroundScreenCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<ChatBackgroundScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(parameters: ChatBackgroundScreenCoordinatorParameters) {
        viewModel = ChatBackgroundScreenViewModel(roomProxy: parameters.roomProxy,
                                                  clientProxy: parameters.userSession.clientProxy,
                                                  chatBackgroundService: parameters.userSession.chatBackgroundService,
                                                  userIndicatorController: parameters.userIndicatorController,
                                                  mediaProvider: parameters.userSession.mediaProvider)
    }

    func start() {
        viewModel.actionsPublisher.sink { [weak self] action in
            guard let self else { return }
            switch action {
            case .dismiss:
                actionsSubject.send(.dismiss)
            }
        }
        .store(in: &cancellables)
    }

    func toPresentable() -> AnyView {
        AnyView(ChatBackgroundScreen(context: viewModel.context))
    }
}
