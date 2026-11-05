//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation

enum EncryptionResetScreenViewModelAction {
    case requestPassword(passwordPublisher: PassthroughSubject<String, Never>)
    /// `completionPublisher` fires when the OAuth approval web sheet is dismissed,
    /// signalling that the reset may now be performed.
    case requestOAuthAuthorisation(url: URL, completionPublisher: PassthroughSubject<OAuthAccountSettingsPresenter.Outcome, Never>)
    /// GUA FORK: the approval landed, so close the web sheet rather than leaving the user to.
    case dismissOAuthPresentation
    case resetFinished
    /// GUA FORK: the user chose to get the keys from another device of theirs instead of resetting.
    case recoverFromOtherDevice
    case cancel
}

struct EncryptionResetScreenViewState: BindableState {
    /// GUA FORK: true only when another device of this account holds the keys, so verifying
    /// with it can bring the messages here without a reset.
    var canRecoverFromOtherDevice = false
    /// GUA FORK: true from the moment the destructive button is pressed until the reset settles.
    /// resetIdentity() deletes the key backup before it even returns the MAS approval URL, so a
    /// second press must never reach it.
    var isResetting = false
    var bindings: EncryptionResetScreenViewStateBindings
}

struct EncryptionResetScreenViewStateBindings {
    var alertInfo: AlertInfo<UUID>?
}

enum EncryptionResetScreenViewAction {
    case reset
    case recoverFromOtherDevice
    case cancel
}
