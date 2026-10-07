//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Combine

@MainActor
protocol AccountAuthorityScreenViewModelProtocol {
    var actionsPublisher: AnyPublisher<AccountAuthorityScreenViewModelAction, Never> { get }
    var context: AccountAuthorityScreenViewModelType.Context { get }
}
