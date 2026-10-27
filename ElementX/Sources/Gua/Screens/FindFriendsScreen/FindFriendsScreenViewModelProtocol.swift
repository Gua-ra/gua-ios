//
// Copyright 2022-2025 New Vector Ltd.
// Copyright 2025 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Combine

@MainActor
protocol FindFriendsScreenViewModelProtocol {
    var actionsPublisher: AnyPublisher<FindFriendsScreenViewModelAction, Never> { get }
    var context: FindFriendsScreenViewModelType.Context { get }
}
