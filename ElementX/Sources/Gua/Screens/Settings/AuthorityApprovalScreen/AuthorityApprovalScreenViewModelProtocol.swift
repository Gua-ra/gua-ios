//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Combine

@MainActor
protocol AuthorityApprovalScreenViewModelProtocol {
    var actionsPublisher: AnyPublisher<AuthorityApprovalScreenViewModelAction, Never> { get }
    var context: AuthorityApprovalScreenViewModelType.Context { get }
}
