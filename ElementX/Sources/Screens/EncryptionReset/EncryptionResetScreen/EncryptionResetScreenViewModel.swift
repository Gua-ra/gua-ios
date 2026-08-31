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
        // GUA FORK: a second tap used to start an entirely NEW reset, minting a new handle and a
        // new MAS approval URL, which is why pressing the button again looped straight back into
        // MAS instead of finishing. There is one reset in flight at a time.
        guard identityResetHandle == nil else {
            MXLog.info("GUA-KEYSTORE: a reset is already awaiting approval, ignoring the tap.")
            return
        }

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
                let oidcAuthorisationPublisher = PassthroughSubject<Void, Never>()
                oidcCancellable = oidcAuthorisationPublisher.sink { [weak self] in
                    guard let self else { return }
                    oidcCancellable = nil
                    Task { await self.resetWithOIDCAuthorisation() }
                }

                actionsSubject.send(.requestOIDCAuthorisation(url: url, completionPublisher: oidcAuthorisationPublisher))
                await pollForOIDCApproval(handle: handle)
            }
        case .failure(let error):
            MXLog.error("Failed resetting encryption with error \(error)")
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
            showErrorToast()
        }
    }
    
    /// Retries the reset until MAS has approved it, then closes the sheet for the user.
    ///
    /// The SDK exposes no approval callback: `IdentityResetHandle` has only `authType()`,
    /// `cancel()` and `reset(auth:)`, and `OAuthCrossSigningResetInfo` carries just the URL. So the
    /// success of `reset(auth: nil)` is the only thing that can tell us the approval landed.
    private func pollForOIDCApproval(handle: IdentityResetHandle) async {
        let deadline = Date().addingTimeInterval(Self.approvalPollTimeout)

        while Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            guard identityResetHandle != nil else { return }

            do {
                try await handle.reset(auth: nil)
            } catch {
                continue // Not approved yet.
            }

            MXLog.info("GUA-KEYSTORE: MAS approved the reset, closing the sheet.")
            oidcCancellable = nil
            identityResetHandle = nil
            actionsSubject.send(.dismissOIDCPresentation)
            actionsSubject.send(.resetFinished)
            return
        }
    }

    /// Long enough for someone to read the MAS page and press Allow, short enough to give up on.
    private static let approvalPollTimeout: TimeInterval = 180

    private func resetWithOIDCAuthorisation() async {
        // The poller may have finished first and cleared the handle; a manual dismissal after that
        // is nothing to act on.
        guard let identityResetHandle else { return }

        showLoadingIndicator()

        defer {
            hideLoadingIndicator()
        }

        do {
            try await identityResetHandle.reset(auth: nil)
            self.identityResetHandle = nil
            actionsSubject.send(.resetFinished)
        } catch {
            MXLog.error("Failed resetting encryption with error \(error)")
            showErrorToast()
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
