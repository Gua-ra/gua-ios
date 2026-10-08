//
// Copyright Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import MatrixRustSDK
import XCTest

/// Ownership of the published recovery state while recovery is being enabled.
///
/// Terminal values (`.enabled`, `.incomplete`, `.disabled`) belong to the SDK: they are what it
/// recomputed, delivered through its recovery-state listener or read back from it. The progress
/// listener owns only the transient `.settingUp`, and the controller must never leave that behind.
///
/// These run against the real controller, built on the generated SDK mock, so the listeners it
/// registers at init are the ones the tests drive.
class SecureBackupControllerStateTests: XCTestCase {
    private var encryption: EncryptionSDKMock!
    private var controller: SecureBackupController!
    private var published: [SecureBackupRecoveryState] = []
    private var cancellables: Set<AnyCancellable> = []

    private struct TransientError: Error { }

    override func setUp() {
        encryption = EncryptionSDKMock()
        encryption.backupStateListenerListenerReturnValue = TaskHandleSDKMock()
        encryption.recoveryStateListenerListenerReturnValue = TaskHandleSDKMock()
        encryption.backupExistsOnServerReturnValue = false

        controller = SecureBackupController(encryption: encryption,
                                            userID: "@state:gua.example",
                                            e2eeInitialization: Task { },
                                            persistRecoveryKey: { _ in })
        published = []
        cancellables = []

        // The account starts `.disabled`, which is the only state that enables recovery.
        givenTheSDKReports(.disabled)
    }

    // MARK: - T1

    /// `Done` is a progress event, not a verdict. When the SDK recomputes `.incomplete`, nothing may
    /// have announced `.enabled` in between.
    func testDoneDoesNotPublishEnabledWhenTheSDKRecomputesIncomplete() async {
        let result = await whenEnablingRecovery(progress: [.starting, .done(recoveryKey: "k")],
                                                returning: .success("k"),
                                                sdkStateAfterwards: .incomplete)

        XCTAssertFalse(published.contains(.enabled), "published: \(published)")
        XCTAssertEqual(published.last, .incomplete)
        XCTAssertEqual(try? result.get(), "k")
    }

    // MARK: - T2

    /// A structural refusal produces no SDK listener update, so the transient `.settingUp` has to
    /// be closed out by the controller itself, with the SDK's current answer.
    func testAStructuralRefusalLeavesSettingUpAndReturnsToTheSDKState() async {
        let result = await whenEnablingRecovery(progress: [.starting],
                                                returning: .failure(RecoveryError.BackupExistsOnServer),
                                                sdkStateAfterwards: .disabled)

        XCTAssertTrue(published.contains(.settingUp), "published: \(published)")
        XCTAssertNotEqual(published.last, .settingUp, "published: \(published)")
        XCTAssertEqual(published.last, .disabled)
        XCTAssertTrue(isFailure(result))
    }

    // MARK: - T3

    /// The terminal `.enabled` is read from the SDK, once, and is not also manufactured from `Done`.
    func testASuccessfulEnableReadsTheSDKStateAndPublishesEnabledOnce() async {
        let result = await whenEnablingRecovery(progress: [.starting, .done(recoveryKey: "k")],
                                                returning: .success("k"),
                                                sdkStateAfterwards: .enabled)

        XCTAssertGreaterThanOrEqual(encryption.recoveryStateCallsCount, 1, "the authoritative state was never read")
        XCTAssertEqual(published.last, .enabled)
        XCTAssertEqual(published.filter { $0 == .enabled }.count, 1, "published: \(published)")
        XCTAssertEqual(try? result.get(), "k")
    }

    // MARK: - T4

    /// After a failed call the SDK still holds the pre-call state. That is what gets published:
    /// the epilogue reports, it does not conclude.
    func testAFailedEnablePublishesThePreCallSDKStateNotSuccess() async {
        let result = await whenEnablingRecovery(progress: [.starting],
                                                returning: .failure(TransientError()),
                                                sdkStateAfterwards: .disabled)

        XCTAssertFalse(published.contains(.enabled), "published: \(published)")
        XCTAssertEqual(published.last, .disabled)
        XCTAssertTrue(isFailure(result))
    }

    // MARK: - T5

    /// An SDK that cannot answer is still a better final value than a transient nobody re-publishes.
    func testAFailedEnablePublishesUnknownRatherThanStayingInSettingUp() async {
        let result = await whenEnablingRecovery(progress: [.starting],
                                                returning: .failure(TransientError()),
                                                sdkStateAfterwards: .unknown)

        XCTAssertNotEqual(published.last, .settingUp, "published: \(published)")
        XCTAssertEqual(published.last, .unknown)
        XCTAssertTrue(isFailure(result))
    }

    // MARK: - helpers

    /// Drives the recovery-state listener the controller registered at init, as the SDK would.
    private func givenTheSDKReports(_ state: RecoveryState) {
        guard let listener = encryption.recoveryStateListenerListenerReceivedListener else {
            return XCTFail("the controller did not register a recovery-state listener")
        }
        listener.onUpdate(status: state)
    }

    /// Runs `generateRecoveryKey` with a fake `enableRecovery` that emits `progress` through the
    /// controller's own progress listener and then returns or throws, while the SDK's read-back
    /// state is `sdkStateAfterwards`. Everything published from the call onwards is collected.
    private func whenEnablingRecovery(progress: [EnableRecoveryProgress],
                                      returning outcome: Result<String, Error>,
                                      sdkStateAfterwards: RecoveryState) async -> Result<String, SecureBackupControllerError> {
        encryption.recoveryStateReturnValue = sdkStateAfterwards
        encryption.enableRecoveryWaitForBackupsToUploadPassphraseProgressListenerClosure = { _, _, listener in
            for step in progress {
                listener.onUpdate(status: step)
            }
            return try outcome.get()
        }

        controller.recoveryState
            .sink { [weak self] in self?.published.append($0) }
            .store(in: &cancellables)

        return await controller.generateRecoveryKey()
    }

    private func isFailure(_ result: Result<String, SecureBackupControllerError>) -> Bool {
        if case .failure = result {
            return true
        }
        return false
    }
}
