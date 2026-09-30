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
    /// GUA FORK: the guard acquired for the reset in progress. The guard releases itself once the
    /// reset call has returned; this screen releases it only while nothing is in flight.
    private var resetGuard: IdentityResetGuardProtocol?
    private var hasReportedLanding = false
    private let approveReset: (URL, String) async -> Bool
    /// How long this screen waits for the upload before reporting that finishing is taking long.
    /// The upload itself is not bounded by it.
    private let resetCallCeiling: Duration

    init(clientProxy: ClientProxyProtocol,
         userIndicatorController: UserIndicatorControllerProtocol,
         approveReset: ((URL, String) async -> Bool)? = nil,
         resetCallCeiling: Duration = .seconds(20)) {
        self.clientProxy = clientProxy
        self.userIndicatorController = userIndicatorController
        self.approveReset = approveReset ?? { url, accessToken in await Self.approveFromApp(approvalURL: url, accessToken: accessToken) }
        self.resetCallCeiling = resetCallCeiling

        super.init(initialViewState: EncryptionResetScreenViewState(bindings: .init()))

        Task { await checkForOtherDevice() }
    }

    // MARK: - Recovery from another device

    /// GUA FORK: offers recovery from another device only when there is one to recover from: this
    /// device is missing keys that exist on the server (recovery is incomplete) AND another device
    /// of the account is signed by the current identity. Whether that device still holds the keys
    /// and answers is only learnt by trying; the flow says so plainly when it does not. Anything
    /// else, and the reset stays the only option.
    private func checkForOtherDevice() async {
        guard clientProxy.secureBackupController.recoveryState.value == .incomplete else { return }
        guard case let .success(hasOtherDevice) = await clientProxy.hasDevicesToVerifyAgainst() else { return }
        MXLog.info("GUA-KEYSTORE: another device signed by the current identity exists: \(hasOtherDevice)")
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
            await resetGuard?.releaseIfIdle()
        }
    }

    // MARK: - Private

    private func startResetFlow() async {
        showLoadingIndicator()

        defer {
            hideLoadingIndicator()
        }

        // GUA FORK: the guard stops the encryption sync and keeps every start away until the reset
        // has settled, so no own-user key query can clear the identity about to be created. When a
        // previous attempt's upload is still running, this press waits for it instead of starting a
        // second reset on top of it.
        let resetGuard = await clientProxy.acquireIdentityResetGuard()
        self.resetGuard = resetGuard
        if let inFlight = resetGuard.inFlightReset {
            hideLoadingIndicator()
            await awaitReset(inFlight)
            return
        }

        switch await clientProxy.resetIdentity() {
        case let .success(handle):
            // If the handle is missing then interactive authentication wasn't
            // necessary and the reset proceeded as normal
            guard let handle else {
                await resetGuard.releaseIfIdle()
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
                // approve the reset for that account. The server accepts the access token the app
                // already uses, for this user only, and the upload can follow at once.
                showFinishingIndicator()
                if let accessToken = clientProxy.accessToken, await approveReset(url, accessToken) {
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
            await resetGuard.releaseIfIdle()
            state.isResetting = false
            showErrorToast()
        }
    }

    func resetWith(password: String) async {
        guard let identityResetHandle, let resetGuard else {
            fatalError("Requested reset flow continuation without a stored handle")
        }

        // The guard owns the call from here and releases itself when it returns. A wrong password
        // ends this attempt; a retry starts a fresh reset.
        let operation = resetGuard.runReset(identityResetHandle,
                                            auth: .password(passwordDetails: .init(identifier: clientProxy.userID, password: password)))
        self.identityResetHandle = nil
        await awaitReset(operation)
    }

    // MARK: Approval from the app's own session

    /// Asks the server to open the reset window for this account, authenticated with the
    /// session's own access token. Returns false when the server does not offer this (an
    /// older deployment) or refuses, in which case the web sheet is the fallback.
    private static func approveFromApp(approvalURL: URL, accessToken: String) async -> Bool {
        guard var components = URLComponents(url: approvalURL, resolvingAgainstBaseURL: false) else {
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

    /// Uploads the new identity now that the approval has landed.
    ///
    /// The call runs under the guard, which alone owns its lifetime: the bindings cannot cancel it,
    /// and a cancelled handle still lets an upload already in flight land, so the guard is released
    /// only when the call returns. This screen waits with a presentation ceiling and, past it, says
    /// that finishing is taking long while the call keeps running.
    private func finishApprovedReset() async {
        guard let identityResetHandle, let resetGuard, !isResetInFlight else { return }

        isResetInFlight = true
        defer { isResetInFlight = false }

        let operation = resetGuard.runReset(identityResetHandle, auth: nil)
        // Nothing may act on the handle again; the guard owns the call.
        self.identityResetHandle = nil
        actionsSubject.send(.dismissOIDCPresentation)

        await awaitReset(operation)
    }

    /// Waits for a reset call up to the presentation ceiling and reports the outcome.
    private func awaitReset(_ operation: Task<Result<Void, Error>, Never>) async {
        showFinishingIndicator()
        let outcome = await Self.race(operation, ceiling: resetCallCeiling)
        hideFinishingIndicator()

        switch outcome {
        case .landed:
            reportLanded()
        case let .failed(error):
            MXLog.error("GUA-KEYSTORE: reset(auth:) failed: \(error)")
            state.isResetting = false
            userIndicatorController.submitIndicator(UserIndicator(title: UntranslatedL10n.guaEncryptionResetFailed))
        case .timedOut:
            MXLog.warning("GUA-KEYSTORE: reset(auth:) has not returned within \(resetCallCeiling); it keeps running under the guard.")
            state.isResetting = false
            userIndicatorController.submitIndicator(UserIndicator(title: UntranslatedL10n.guaEncryptionResetStillFinishing))

            Task { [weak self] in
                let result = await operation.value
                guard let self else { return }
                switch result {
                case .success:
                    reportLanded()
                case let .failure(error):
                    MXLog.error("GUA-KEYSTORE: reset(auth:) failed after the ceiling: \(error)")
                    userIndicatorController.submitIndicator(UserIndicator(title: UntranslatedL10n.guaEncryptionResetFailed))
                }
            }
        }
    }

    /// `.resetFinished` is sent once per landing, however many waits observed it.
    private func reportLanded() {
        guard !hasReportedLanding else { return }
        hasReportedLanding = true
        MXLog.info("GUA-KEYSTORE: the new identity is on the server; handing over to provisioning.")
        // isResetting stays set: .resetFinished does not dismiss this screen; the flow coordinator
        // holds the user on a visible wait while key storage is provisioned.
        actionsSubject.send(.resetFinished)
    }

    /// Ends an attempt whose reset call never started and returns the screen to a retryable state.
    ///
    /// `cancel()` is only ever called on a handle whose call did not start; a call that did start
    /// is the guard's to finish. A retry starts a fresh reset.
    private func abandonAttempt() async {
        actionsSubject.send(.dismissOIDCPresentation)
        if let identityResetHandle {
            await identityResetHandle.cancel()
        }
        identityResetHandle = nil
        await resetGuard?.releaseIfIdle()
        state.isResetting = false
    }

    private enum ResetCallOutcome {
        case landed
        case failed(Error)
        case timedOut
    }

    /// Resolves with the call's result or the ceiling, whichever comes first. The ceiling does not
    /// cancel the call: it belongs to the guard and keeps running. A task group cannot express this,
    /// because it waits for every child, and the child awaiting the call cannot be interrupted.
    private static func race(_ operation: Task<Result<Void, Error>, Never>, ceiling: Duration) async -> ResetCallOutcome {
        let gate = ResetOutcomeGate()

        return await withCheckedContinuation { (continuation: CheckedContinuation<ResetCallOutcome, Never>) in
            Task {
                switch await operation.value {
                case .success: gate.resume(continuation, with: .landed)
                case let .failure(error): gate.resume(continuation, with: .failed(error))
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
