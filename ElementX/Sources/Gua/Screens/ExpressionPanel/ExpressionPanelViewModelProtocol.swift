//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine

protocol ExpressionPanelViewModelProtocol {
    var actions: AnyPublisher<ExpressionPanelViewModelAction, Never> { get }
    var context: ExpressionPanelViewModelType.Context { get }
    
    func process(composerAction: ComposerToolbarViewModelAction)
}
