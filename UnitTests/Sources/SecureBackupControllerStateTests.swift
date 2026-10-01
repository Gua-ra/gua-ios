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
                                            userID: "@state:dev.gua.sarahlacerda.me",
                                            e2eeInitialization: Task { },
                                            persistRecoveryKey: { _ in })
        published = []
        cancellables = []

        givenTheSDKReports(.disabled)
    }

    // MARK: - T1

    func testDoneDoesNotPublishEnabledWhenTheSDKRecomputesIncomplete() async {
        let result = await whenEnablingRecovery(progress: [.starting, .done(recoveryKey: "k")],
                                                returning: .success("k"),
                                                sdkStateAfterwards: .incomplete)

        XCTAssertFalse(published.contains(.enabled), "published: \(published)")
        XCTAssertEqual(published.last, .incomplete)
        XCTAssertEqual(try? result.get(), "k")
    }

    // MARK: - T2

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

    func testAFailedEnablePublishesThePreCallSDKStateNotSuccess() async {
        let result = await whenEnablingRecovery(progress: [.starting],
                                                returning: .failure(TransientError()),
                                                sdkStateAfterwards: .disabled)

        XCTAssertFalse(published.contains(.enabled), "published: \(published)")
        XCTAssertEqual(published.last, .disabled)
        XCTAssertTrue(isFailure(result))
    }

    // MARK: - T5

    func testAFailedEnablePublishesUnknownRatherThanStayingInSettingUp() async {
        let result = await whenEnablingRecovery(progress: [.starting],
                                                returning: .failure(TransientError()),
                                                sdkStateAfterwards: .unknown)

        XCTAssertNotEqual(published.last, .settingUp, "published: \(published)")
        XCTAssertEqual(published.last, .unknown)
        XCTAssertTrue(isFailure(result))
    }

    // MARK: - helpers

    private func givenTheSDKReports(_ state: RecoveryState) {
        guard let listener = encryption.recoveryStateListenerListenerReceivedListener else {
            return XCTFail("the controller did not register a recovery-state listener")
        }
        listener.onUpdate(status: state)
    }

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
