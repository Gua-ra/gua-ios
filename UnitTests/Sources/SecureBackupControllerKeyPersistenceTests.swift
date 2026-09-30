//
// Copyright Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import MatrixRustSDK
import XCTest

/// A recovery key minted by `enableRecovery` is the only credential for the secret store that was
/// just created. It is persisted the moment it exists, before any state is read, waited on or
/// judged, and regardless of whether the account goes on to reach `.enabled`. Persisting it is not
/// success; the two never merge.
///
/// These run against the real controller on the generated SDK mock, with the persistence capability
/// `UserSessionStore` would lend it replaced by a recorder.
class SecureBackupControllerKeyPersistenceTests: XCTestCase {
    private var encryption: EncryptionSDKMock!
    private var controller: SecureBackupController!
    private var persisted: [String] = []
    private var events: [String] = []

    private struct TransientError: Error { }

    override func setUp() {
        encryption = EncryptionSDKMock()
        encryption.backupStateListenerListenerReturnValue = TaskHandleSDKMock()
        encryption.recoveryStateListenerListenerReturnValue = TaskHandleSDKMock()
        encryption.backupExistsOnServerReturnValue = false
        encryption.recoveryStateReturnValue = .disabled
        persisted = []
        events = []

        controller = SecureBackupController(encryption: encryption,
                                            userID: "@persist:dev.gua.sarahlacerda.me",
                                            e2eeInitialization: Task { },
                                            persistRecoveryKey: { [weak self] key in
                                                self?.persisted.append(key)
                                                self?.events.append("persist")
                                            })

        // The account starts `.disabled`, the one state that provisions without a reset.
        givenTheSDKReports(.disabled)
    }

    // MARK: - persistence happens at the mint, before anything else

    func testAMintedKeyIsPersistedBeforeItIsReturnedToAnyCaller() async throws {
        givenEnableAttempts([.success("new-key")])

        let key = try await controller.enableRecoveryReturningKey()
        events.append("returned")

        XCTAssertEqual(key, "new-key")
        XCTAssertEqual(persisted, ["new-key"])
        XCTAssertEqual(events, ["mint", "persist", "returned"])
    }

    /// The caller's verdict comes from the state the SDK reports after the call. Here that report is
    /// delayed, so the order between persisting and judging is observable rather than assumed.
    func testTheKeyIsPersistedBeforeTheCallerEvaluatesTheFinalState() async {
        givenEnableAttempts([.success("new-key")], thenAfterADelayTheSDKReports: .enabled)

        let outcome = await controller.repairWithoutReset()

        XCTAssertEqual(outcome, .repaired)
        XCTAssertEqual(persisted, ["new-key"])
        XCTAssertEqual(events, ["mint", "persist", "sdk-enabled"])
    }

    // MARK: - persistence is not success

    /// A device without the private cross-signing keys mints a store it cannot complete. The key is
    /// still the credential for that store, so it is kept; the outcome is still not a repair.
    func testAKeyIsPersistedEvenWhenRecoveryStaysIncomplete() async {
        givenEnableAttempts([.success("new-key")], andBeforeReturningTheSDKReports: .incomplete)

        let outcome = await controller.repairWithoutReset()

        XCTAssertEqual(persisted, ["new-key"], "the key opens the store that was actually created")
        XCTAssertNotEqual(outcome, .repaired)
        XCTAssertEqual(outcome, .resetRequired)
    }

    func testNothingIsPersistedWhenEnableThrowsBeforeMintingAKey() async {
        givenEnableAttempts([.failure(RecoveryError.BackupExistsOnServer)])

        let outcome = await controller.repairWithoutReset()

        XCTAssertTrue(persisted.isEmpty, "persisted: \(persisted)")
        XCTAssertEqual(outcome, .resetRequired)
        XCTAssertEqual(encryption.disableRecoveryCallsCount, 0)
    }

    // MARK: - repeated attempts

    /// After a reset the first successful mint is decisive. A store the device cannot complete is not
    /// improved by another store, so the loop stops with the one key it minted, which opens that store.
    /// This is the loop `provisionAfterReset` runs, driven with the same closure it supplies.
    func testTheFirstSuccessfulMintAfterAResetIsDecisive() async {
        givenEnableAttempts([.success("key-1"), .success("key-2")])

        let outcome = await SecureBackupController.provisionLoop(backoff: [.milliseconds(1), .milliseconds(1), .milliseconds(1)],
                                                                 isEnabled: { false },
                                                                 enableRecovery: { [controller] in
                                                                     _ = try await controller!.enableRecoveryReturningKey()
                                                                 },
                                                                 authoritativeState: { .incomplete },
                                                                 waitForEnabled: { _ in false })

        XCTAssertEqual(persisted, ["key-1"], "exactly one store is minted")
        XCTAssertEqual(outcome, .identityIncompleteAfterReset)
        XCTAssertEqual(encryption.enableRecoveryWaitForBackupsToUploadPassphraseProgressListenerCallsCount, 1)
    }

    /// A thrown attempt minted nothing, so it is still retried; the key retained is the one from the
    /// attempt that finally minted.
    func testAThrownAttemptIsRetriedAndTheMintedKeyIsRetained() async {
        givenEnableAttempts([.failure(TransientError()), .success("key-2")])

        let outcome = await SecureBackupController.provisionLoop(backoff: [.milliseconds(1), .milliseconds(1)],
                                                                 isEnabled: { false },
                                                                 enableRecovery: { [controller] in
                                                                     _ = try await controller!.enableRecoveryReturningKey()
                                                                 },
                                                                 authoritativeState: { [weak self] in self?.persisted.isEmpty == false ? .enabled : .disabled },
                                                                 waitForEnabled: { _ in false })

        XCTAssertEqual(persisted, ["key-2"])
        XCTAssertEqual(outcome, .repaired)
    }

    // MARK: - helpers

    /// Drives the recovery-state listener the controller registered at init, as the SDK would.
    private func givenTheSDKReports(_ state: RecoveryState) {
        guard let listener = encryption.recoveryStateListenerListenerReceivedListener else {
            return XCTFail("the controller did not register a recovery-state listener")
        }
        listener.onUpdate(status: state)
    }

    /// Scripts successive `enableRecovery` calls. Each attempt records "mint" when it produces a key.
    /// `andBeforeReturningTheSDKReports` models the SDK recomputing inside the call, as it does;
    /// `thenAfterADelayTheSDKReports` models the listener delivering after the call has returned.
    private func givenEnableAttempts(_ attempts: [Result<String, Error>],
                                     andBeforeReturningTheSDKReports stateBeforeReturn: RecoveryState? = nil,
                                     thenAfterADelayTheSDKReports delayedState: RecoveryState? = nil) {
        var remaining = attempts
        encryption.enableRecoveryWaitForBackupsToUploadPassphraseProgressListenerClosure = { [weak self] _, _, _ in
            guard let self else { throw TransientError() }
            guard !remaining.isEmpty else {
                XCTFail("enableRecovery called more often than scripted")
                throw TransientError()
            }
            let attempt = remaining.removeFirst()
            let key = try attempt.get()
            events.append("mint")

            if let stateBeforeReturn {
                givenTheSDKReports(stateBeforeReturn)
            }
            if let delayedState {
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(300))
                    self?.events.append("sdk-enabled")
                    self?.givenTheSDKReports(delayedState)
                }
            }
            return key
        }
    }
}
