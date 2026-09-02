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
        case let .success(handle):
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
            case let .oAuth(oidcInfo):
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
        case let .failure(error):
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

        // GUA FORK: bound the call, then judge by outcome rather than by whether it returned.
        //
        // reset(auth:) does four things: it deletes the key backup and secret storage, runs the
        // cross-signing reset that MAS just approved, and then re-enables key backups -- and that
        // last step needs a live sync. On a real phone the approval sheet makes the app inactive,
        // the app stops sync about thirty seconds later, and anyone who spends longer than that
        // reading the MAS page comes back to a sync that has only just been asked to restart. The
        // upload succeeds, the backup step waits on a sync that is not there yet, and the call
        // times out after two to three minutes. That was reported as "Loading… for three minutes,
        // then an error, then the banner is still there" -- an error for something that had in
        // fact worked. The simulator never resigns active behind the sheet, which is why it never
        // showed this.
        //
        // So: kick sync, give the call a bounded window, and whatever it says, hand over to
        // provisioning. Provisioning is judged on the recovery state and can only reach .enabled
        // if the new cross-signing keys are really there, so it is the honest verdict on whether
        // the reset landed. Calling reset(auth:) a second time would delete the backup again, so
        // that is exactly what this must not do.
        clientProxy.startSync()

        let outcome = await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                do {
                    try await identityResetHandle.reset(auth: nil)
                    return true
                } catch {
                    MXLog.error("Failed resetting encryption with error \(error)")
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(for: Self.resetCallCeiling)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        switch outcome {
        case true:
            MXLog.info("GUA-KEYSTORE: reset(auth:) returned; handing over to provisioning.")
        case false where !surfacingFailure:
            MXLog.info("GUA-KEYSTORE: reset attempt ended unapproved, will ask again.")
            return false
        case false:
            MXLog.warning("GUA-KEYSTORE: reset(auth:) threw; provisioning will say whether it landed.")
            await identityResetHandle.cancel()
        case nil:
            MXLog.warning("GUA-KEYSTORE: reset(auth:) ran past its ceiling; provisioning will say whether it landed.")
            await identityResetHandle.cancel()
        }

        // Drop the handle BEFORE dismissing: the send is synchronous through Combine and reaches
        // the presenter, whose dismissal fires the completion publisher, and with the handle still
        // populated that used to re-enter here and start a fresh reset.
        self.identityResetHandle = nil

        // Deliberately NOT clearing isResetting. .resetFinished does not dismiss this screen; the
        // flow coordinator holds the user on a visible wait while key storage is provisioned, shows
        // the verdict, and only then sends .resetComplete. Clearing the flag here put the
        // destructive button back within reach for that whole window.
        actionsSubject.send(.dismissOIDCPresentation)
        actionsSubject.send(.resetFinished)
        return true
    }

    /// How long a single reset(auth:) call may hold the user before provisioning takes over.
    ///
    /// Generous for the happy path, which settles in a couple of seconds, and short enough that a
    /// sync-starved backup step cannot turn into minutes of "Loading…".
    private static let resetCallCeiling: Duration = .seconds(30)

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
