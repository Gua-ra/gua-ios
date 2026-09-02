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
    /// GUA FORK: true while an upload is in flight, so a second one can never start on the same
    /// handle. Each reset deletes the key backup and secret storage again, so a concurrent call is
    /// destructive, not just noisy.
    private var isResetInFlight = false

    init(clientProxy: ClientProxyProtocol, userIndicatorController: UserIndicatorControllerProtocol) {
        self.clientProxy = clientProxy
        self.userIndicatorController = userIndicatorController

        super.init(initialViewState: EncryptionResetScreenViewState(bindings: .init()))

        Task { await checkForOtherDevice() }
    }

    // MARK: - Recovery from another device

    /// GUA FORK: offers recovery from another device only when it can actually work: this device
    /// is missing keys that exist on the server (recovery is incomplete) AND another device of the
    /// account is signed by the current identity, so a verification with it hands the keys over.
    /// Anything else, and the reset stays the only option.
    private func checkForOtherDevice() async {
        guard clientProxy.secureBackupController.recoveryState.value == .incomplete else { return }
        guard case let .success(hasOtherDevice) = await clientProxy.hasDevicesToVerifyAgainst() else { return }
        MXLog.info("GUA-KEYSTORE: another device holds the keys: \(hasOtherDevice)")
        state.canRecoverFromOtherDevice = hasOtherDevice
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
        case .recoverFromOtherDevice:
            guard !state.isResetting else { return }
            actionsSubject.send(.recoverFromOtherDevice)
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

            // GUA FORK: from here on this account carries a freshly minted identity that the
            // server has never seen. Until an approval lands it, the setup banner must not try
            // to repair around it. See IdentityResetPendingStore.
            IdentityResetPendingStore.markPending(for: clientProxy.userID)

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

                // GUA FORK: approve from the app's own session first. The web sheet shares cookies
                // with the system browser, which on most phones holds no session at all (sign-in
                // uses an ephemeral browser context), so the page would demand a whole new
                // phone-number login; on a phone whose browser holds another account it would
                // approve the reset for that account. The server now accepts the access token the
                // app already uses, for this user only, and the upload can follow at once.
                showFinishingIndicator()
                if await approveFromApp(approvalURL: url) {
                    await finishApprovedReset()
                    return
                }
                hideFinishingIndicator()

                // Older servers: fall back to the web sheet. Nothing runs while it is open. The
                // approval page hands control back to the app once the user has approved, and
                // that is the moment to upload. The sheet closing by hand means no approval.
                let outcomePublisher = PassthroughSubject<OIDCAccountSettingsPresenter.Outcome, Never>()
                oidcCancellable = outcomePublisher.sink { [weak self] outcome in
                    guard let self else { return }
                    oidcCancellable = nil
                    Task { await self.handleApprovalSheet(outcome: outcome) }
                }

                actionsSubject.send(.requestOIDCAuthorisation(url: url, completionPublisher: outcomePublisher))
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

    // MARK: Approval from the app's own session

    /// Asks the server to open the reset window for this account, authenticated with the
    /// session's own access token. Returns false when the server does not offer this (an
    /// older deployment) or refuses, in which case the web sheet is the fallback.
    private func approveFromApp(approvalURL: URL) async -> Bool {
        guard let accessToken = clientProxy.accessToken,
              var components = URLComponents(url: approvalURL, resolvingAgainstBaseURL: false) else {
            return false
        }
        components.path = "/api/gua/identity-reset/allow"
        components.query = nil
        components.fragment = nil
        guard let endpoint = components.url else { return false }

        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode else { return false }
            if (200..<300).contains(status) {
                MXLog.info("GUA-KEYSTORE: reset approved from the app's own session.")
                return true
            }
            MXLog.warning("GUA-KEYSTORE: app-side approval answered \(status); falling back to the web sheet.")
            return false
        } catch {
            MXLog.warning("GUA-KEYSTORE: app-side approval failed (\(error)); falling back to the web sheet.")
            return false
        }
    }

    // MARK: Approval sheet outcome

    private func handleApprovalSheet(outcome: OIDCAccountSettingsPresenter.Outcome) async {
        switch outcome {
        case .dismissed:
            // Closed without approving. Nothing to upload, so nothing to wait for: say so, and
            // put the button back. The pending marker stays, because the backup is already gone
            // and only finishing the reset can put the account right.
            MXLog.info("GUA-KEYSTORE: approval sheet dismissed without approving.")
            await abandonAttempt()
            userIndicatorController.submitIndicator(UserIndicator(title: UntranslatedL10n.guaEncryptionResetNotApproved))
        case .returned:
            await finishApprovedReset()
        }
    }

    /// Uploads the new identity now that the approval page has handed control back.
    ///
    /// The SDK call is the verdict. It returns normally only after the server has accepted both
    /// uploads, and `cancel()` is never called on a handle whose result is still being trusted:
    /// a cancelled call returns success without uploading anything, which is exactly the false
    /// success this flow must never produce.
    ///
    /// The call cannot be interrupted from Swift, so the wait on it is bounded separately. If it
    /// has not returned by then the attempt is given up on, the user is told plainly, and the
    /// destructive button comes back. Once approved, a good network settles in a second or two.
    private func finishApprovedReset() async {
        guard let identityResetHandle, !isResetInFlight else { return }

        isResetInFlight = true
        showFinishingIndicator()
        defer {
            isResetInFlight = false
            hideFinishingIndicator()
        }

        clientProxy.startSync()

        let outcome = await Self.awaitReset(on: identityResetHandle, ceiling: Self.resetCallCeiling)

        switch outcome {
        case .landed:
            MXLog.info("GUA-KEYSTORE: the new identity is on the server; handing over to provisioning.")
            // Drop the handle BEFORE dismissing: the send is synchronous through Combine and reaches
            // the presenter, whose dismissal fires the completion publisher, and with the handle
            // still populated that used to re-enter here.
            self.identityResetHandle = nil
            // Deliberately NOT clearing isResetting. .resetFinished does not dismiss this screen;
            // the flow coordinator holds the user on a visible wait while key storage is
            // provisioned, shows the verdict, and only then sends .resetComplete.
            actionsSubject.send(.dismissOIDCPresentation)
            actionsSubject.send(.resetFinished)
        case let .failed(error):
            MXLog.error("GUA-KEYSTORE: reset(auth:) threw after the approval came back: \(error)")
            await abandonAttempt()
            userIndicatorController.submitIndicator(UserIndicator(title: UntranslatedL10n.guaEncryptionResetFailed))
        case .timedOut:
            MXLog.warning("GUA-KEYSTORE: reset(auth:) has not returned within \(Self.resetCallCeiling); giving up on this attempt.")
            await abandonAttempt()
            userIndicatorController.submitIndicator(UserIndicator(title: UntranslatedL10n.guaEncryptionResetFailed))
        }
    }

    /// Stops trusting the current handle and returns the screen to a retryable state.
    ///
    /// `cancel()` is only ever called here, after the attempt's result has been discarded, so its
    /// habit of making `reset()` return success can no longer mislead anyone. A retry starts a
    /// fresh reset, which is safe: the server side is idempotent and the approval window is long.
    private func abandonAttempt() async {
        actionsSubject.send(.dismissOIDCPresentation)
        if let identityResetHandle {
            await identityResetHandle.cancel()
        }
        identityResetHandle = nil
        state.isResetting = false
    }

    private enum ResetCallOutcome {
        case landed
        case failed(Error)
        case timedOut
    }

    /// Runs `reset(auth: nil)` and resolves with whichever comes first: its result, or the ceiling.
    ///
    /// The SDK call keeps running past the ceiling because the bindings cannot cancel it; its
    /// late result is simply dropped. That is why the caller must never act on the handle again
    /// except to cancel it.
    private static func awaitReset(on handle: IdentityResetHandle, ceiling: Duration) async -> ResetCallOutcome {
        let gate = ResetOutcomeGate()

        return await withCheckedContinuation { (continuation: CheckedContinuation<ResetCallOutcome, Never>) in
            Task {
                do {
                    try await handle.reset(auth: nil)
                    gate.resume(continuation, with: .landed)
                } catch {
                    gate.resume(continuation, with: .failed(error))
                }
            }
            Task {
                try? await Task.sleep(for: ceiling)
                gate.resume(continuation, with: .timedOut)
            }
        }
    }

    /// Resumes a continuation exactly once, whichever task gets there first.
    private final class ResetOutcomeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false

        func resume(_ continuation: CheckedContinuation<ResetCallOutcome, Never>, with outcome: ResetCallOutcome) {
            lock.lock()
            defer { lock.unlock() }
            guard !resumed else { return }
            resumed = true
            continuation.resume(returning: outcome)
        }
    }

    /// How long the upload may take once the approval page has handed control back.
    ///
    /// Generous for the happy path, which settles in a second or two, and short enough that a
    /// refused upload cannot turn into minutes of spinner.
    private static let resetCallCeiling: Duration = .seconds(20)

    // MARK: Toasts and loading indicators

    private static let loadingIndicatorIdentifier = "\(EncryptionResetScreenViewModel.self)-Loading"
    private static let finishingIndicatorIdentifier = "\(EncryptionResetScreenViewModel.self)-Finishing"

    private func showLoadingIndicator() {
        userIndicatorController.submitIndicator(UserIndicator(id: Self.loadingIndicatorIdentifier,
                                                              type: .modal,
                                                              title: L10n.commonLoading,
                                                              persistent: true))
    }

    private func hideLoadingIndicator() {
        userIndicatorController.retractIndicatorWithId(Self.loadingIndicatorIdentifier)
    }

    private func showFinishingIndicator() {
        userIndicatorController.submitIndicator(UserIndicator(id: Self.finishingIndicatorIdentifier,
                                                              type: .modal,
                                                              title: UntranslatedL10n.guaEncryptionResetFinishing,
                                                              persistent: true))
    }

    private func hideFinishingIndicator() {
        userIndicatorController.retractIndicatorWithId(Self.finishingIndicatorIdentifier)
    }

    private func showErrorToast() {
        userIndicatorController.submitIndicator(UserIndicator(title: L10n.errorUnknown))
    }
}
