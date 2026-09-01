//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import MatrixRustSDK
import SwiftUI

typealias EncryptionResetScreenViewModelType = StateStoreViewModelV2<EncryptionResetScreenViewState, EncryptionResetScreenViewAction>

class EncryptionResetScreenViewModel: EncryptionResetScreenViewModelType, EncryptionResetScreenViewModelProtocol {
    private let clientProxy: ClientProxyProtocol
    private let userIndicatorController: UserIndicatorControllerProtocol
    
    private let actionsSubject: PassthroughSubject<EncryptionResetScreenViewModelAction, Never> = .init()
    var actionsPublisher: AnyPublisher<EncryptionResetScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    private var identityResetHandle: IdentityResetHandle?
    private var passwordCancellable: AnyCancellable?
    private var oidcCancellable: AnyCancellable?
    /// GUA FORK: true while a reset(auth:) is in flight, so a second one can never start.
    ///
    /// The handle alone could not carry this. It is only cleared once a reset SUCCEEDS, so during
    /// the minutes that reset(auth: nil) spends waiting for MAS approval it is still non-nil, and
    /// closing the sheet by hand ran a second concurrent reset on it. Per the SDK, each reset
    /// deletes the key backup and secret storage again, so that was not merely noisy.
    private var isResetInFlight = false

    init(clientProxy: ClientProxyProtocol, userIndicatorController: UserIndicatorControllerProtocol) {
        self.clientProxy = clientProxy
        self.userIndicatorController = userIndicatorController
        
        super.init(initialViewState: EncryptionResetScreenViewState(bindings: .init()))
    }
    
    // MARK: - Public
    
    override func process(viewAction: EncryptionResetScreenViewAction) {
        switch viewAction {
        case .reset:
            // GUA FORK: straight through, no second confirmation. The screen behind this button
            // already names what is lost and the button itself is destructive; the alert that used
            // to sit here asked "are you sure you want to reset your digital identity?", which is
            // jargon on top of a confirmation the user had just given.
            // The flag is set here, synchronously, not inside startResetFlow: the handle it used
            // to guard on is only assigned after resetIdentity() returns, and resetIdentity() is
            // itself the call that deletes the key backup. A second press in that window started a
            // second destructive reset.
            guard !state.isResetting else { return }
            state.isResetting = true
            Task { await startResetFlow() }
        case .cancel:
            actionsSubject.send(.cancel)
        }
    }

    func stop() {
        Task {
            await identityResetHandle?.cancel()
        }
    }

    // MARK: - Private

    private func startResetFlow() async {
        showLoadingIndicator()
        
        defer {
            hideLoadingIndicator()
        }
        
        switch await clientProxy.resetIdentity() {
        case .success(let handle):
            // If the handle is missing then interactive authentication wasn't
            // necessary and the reset proceeded as normal
            guard let handle else {
                actionsSubject.send(.resetFinished)
                return
            }
            
            identityResetHandle = handle
            
            switch handle.authType() {
            case .uiaa:
                let passwordPublisher = PassthroughSubject<String, Never>()
                passwordCancellable = passwordPublisher.sink { [weak self] password in
                    guard let self else { return }
                    passwordCancellable = nil
                    Task { await self.resetWith(password: password) }
                }
                
                actionsSubject.send(.requestPassword(passwordPublisher: passwordPublisher))
            case .oAuth(let oidcInfo):
                guard let url = URL(string: oidcInfo.approvalUrl) else {
                    fatalError("Invalid URL received through identity reset handle: \(oidcInfo.approvalUrl)")
                }

                hideLoadingIndicator()

                // The reset must only be performed *after* the user has approved it in the
                // MAS web sheet. Calling reset(auth: nil) immediately (as before) made the
                // server reject the unapproved cross-signing key upload, leaving the device
                // unverified and the identity-confirmation gate looping forever. Wait for the
                // sheet to be dismissed (signalled on the publisher) before resetting — this
                // mirrors how the UIAA/password path waits for the entered password.
                // GUA FORK: MAS gives us no completion signal. Its approval page never navigates
                // to the app's callback URL, so ASWebAuthenticationSession has no reason to close
                // itself and the only event we ever receive is "the user dismissed it" — which is
                // indistinguishable from them cancelling. That is why the sheet sat there telling
                // people to go back to the app, and why they had to close it by hand.
                //
                // reset(auth: nil) succeeding IS the authoritative "MAS approved it" signal, so
                // poll that instead of waiting to be told. The moment it succeeds we close the
                // sheet ourselves and finish. Dismissing by hand still works: the publisher fires
                // and we make one final attempt.
                // The sheet closing IS the signal, and it is the only one there is.
                //
                // Running reset(auth: nil) while the sheet is open was the mistake. Its approval
                // budget is about two minutes and it starts when the sheet opens, so it is spent on
                // the time the user takes to read the page. Worse, it holds isResetInFlight for
                // that whole window, so when they did close the sheet the close was ignored, the
                // destructive button behind it stayed disabled, and the only way out was Cancel --
                // with the banner still up afterwards, because nothing had finished.
                //
                // So nothing runs until the sheet goes. By then the approval is in force and a
                // single call settles in about a second. If they closed it without approving, that
                // call fails and says so, which is the honest outcome for that case.
                let oidcAuthorisationPublisher = PassthroughSubject<Void, Never>()
                oidcCancellable = oidcAuthorisationPublisher.sink { [weak self] in
                    guard let self else { return }
                    oidcCancellable = nil
                    Task { await self.resetWithOIDCAuthorisation(showingIndicator: true) }
                }

                actionsSubject.send(.requestOIDCAuthorisation(url: url, completionPublisher: oidcAuthorisationPublisher))
            }
        case .failure(let error):
            MXLog.error("Failed resetting encryption with error \(error)")
            state.isResetting = false
            showErrorToast()
        }
    }
    
    func resetWith(password: String) async {
        guard let identityResetHandle else {
            fatalError("Requested reset flow continuation without a stored handle")
        }
        
        showLoadingIndicator()
        
        defer {
            hideLoadingIndicator()
        }
        
        do {
            try await identityResetHandle.reset(auth: .password(passwordDetails: .init(identifier: clientProxy.userID, password: password)))
            actionsSubject.send(.resetFinished)
        } catch {
            MXLog.error("Failed resetting encryption with error \(error)")
            // Without this the button stays disabled and the screen cannot be escaped except by
            // Cancel, with the key backup already destroyed.
            state.isResetting = false
            showErrorToast()
        }
    }
    
    /// Returns true once the reset has actually landed, false if this attempt did not get there.
    ///
    /// `surfacingFailure` is false while the approval sheet is still open. An attempt that fails
    /// there has almost always simply run out its two minute budget with the user still reading the
    /// page, which is not a failure of anything -- the approval may be seconds away. Treating it as
    /// one is what tore the flow down mid-approval and dropped people back on the banner with their
    /// backup already destroyed. The caller retries instead; the user always has Cancel.
    @discardableResult
    private func resetWithOIDCAuthorisation(showingIndicator: Bool, surfacingFailure: Bool = true) async -> Bool {
        // Nothing to act on if a reset already succeeded and cleared the handle, and nothing to
        // start if one is already running: each reset(auth:) deletes the backup and secret storage
        // again, so a second concurrent call is destructive, not just wasteful.
        guard let identityResetHandle, !isResetInFlight else { return false }

        isResetInFlight = true
        if showingIndicator {
            showLoadingIndicator()
        }

        defer {
            isResetInFlight = false
            if showingIndicator {
                hideLoadingIndicator()
            }
        }

        do {
            try await identityResetHandle.reset(auth: nil)
            self.identityResetHandle = nil
            // Deliberately NOT clearing isResetting here. .resetFinished does not dismiss this
            // screen: the flow coordinator first awaits the key-storage repair and only then sends
            // .resetComplete, which is what actually closes it. Clearing the flag on this line put
            // the destructive button back within reach for that whole window, on the screen the
            // user is still looking at, and one press there ran resetIdentity() a second time,
            // deleting the key backup again and minting a fresh MAS approval URL. That was the
            // loop back to MAS. The screen is on its way out; the button stays disabled.
            //
            // MAS never navigates its approval page to the app's callback, so the web sheet has no
            // reason to close itself. Now that the approval has demonstrably landed, close it.
            actionsSubject.send(.dismissOIDCPresentation)
            actionsSubject.send(.resetFinished)
            return true
        } catch {
            MXLog.error("Failed resetting encryption with error \(error)")

            guard surfacingFailure else {
                // The sheet is still up and the handle is still good. Keep both: the next attempt
                // is what picks the approval up once the user gets to it.
                MXLog.info("GUA-KEYSTORE: reset attempt ended unapproved, will ask again.")
                return false
            }

            // Drop the handle BEFORE dismissing, mirroring the success path. The send below is
            // synchronous through Combine and reaches the presenter, whose dismissal fires the
            // completion publisher; with the handle still populated that re-entered here and
            // started a fresh full-length reset with no approval page on screen.
            await identityResetHandle.cancel()
            self.identityResetHandle = nil

            // The sheet is still open on this path, and MAS will not close it. Take it away rather
            // than leave the user reading an approval page that can no longer lead anywhere.
            actionsSubject.send(.dismissOIDCPresentation)
            showErrorToast()

            // Leave, rather than clearing isResetting and putting a destructive button back under
            // the thumb of someone stranded on a screen whose backup is already gone. Pressing it
            // is what looped them back into MAS. The banner is still on the chat list behind this,
            // so retrying stays one tap away, from a screen that can actually explain itself.
            actionsSubject.send(.cancel)
            return false
        }
    }
    
    // MARK: Toasts and loading indicators
    
    private static let loadingIndicatorIdentifier = "\(EncryptionResetScreenViewModel.self)-Loading"
    
    private func showLoadingIndicator() {
        userIndicatorController.submitIndicator(UserIndicator(id: Self.loadingIndicatorIdentifier,
                                                              type: .modal,
                                                              title: L10n.commonLoading,
                                                              persistent: true))
    }
    
    private func hideLoadingIndicator() {
        userIndicatorController.retractIndicatorWithId(Self.loadingIndicatorIdentifier)
    }
    
    private func showErrorToast() {
        userIndicatorController.submitIndicator(UserIndicator(title: L10n.errorUnknown))
    }
}
