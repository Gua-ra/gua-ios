//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine

@MainActor
protocol ChatBackgroundScreenViewModelProtocol {
    var actionsPublisher: AnyPublisher<ChatBackgroundScreenViewModelAction, Never> { get }
    var context: ChatBackgroundScreenViewModelType.Context { get }
}
