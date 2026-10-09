//
// Copyright Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import MatrixRustSDK
import XCTest

class SecureBackupControllerStoredKeyTests: XCTestCase {
    private var encryption: EncryptionSDKMock!
    private var controller: SecureBackupController!
    private var storedKey: String?
    private var persisted: [String] = []

    private struct WrongKeyError: Error { }

    override func setUp() {
        encryption = EncryptionSDKMock()
        encryption.backupStateListenerListenerReturnValue = TaskHandleSDKMock()
        encryption.recoveryStateListenerListenerReturnValue = TaskHandleSDKMock()
        encryption.backupExistsOnServerReturnValue = true
        encryption.recoveryStateReturnValue = .enabled
        storedKey = nil
        persisted = []

        controller = SecureBackupController(encryption: encryption,
                                            userID: "@alice:example.org",
                                            e2eeInitialization: Task { },
                                            persistRecoveryKey: { [weak self] key in self?.persisted.append(key) },
                                            storedRecoveryKey: { [weak self] in self?.storedKey })
    }

    func testWithoutAStoredKeyTheBackupIsNotConfirmed() async {
        let confirmed = await controller.confirmCurrentBackupWithStoredKey()

        XCTAssertFalse(confirmed)
        XCTAssertFalse(encryption.recoverRecoveryKeyCalled)
    }

    func testAStoredKeyThatOpensKeyStorageConfirmsTheBackup() async {
        storedKey = "stored-key"

        let confirmed = await controller.confirmCurrentBackupWithStoredKey()

        XCTAssertTrue(confirmed)
        XCTAssertEqual(encryption.recoverRecoveryKeyReceivedRecoveryKey, "stored-key")
    }

    func testAStoredKeyTheSDKRejectsDoesNotConfirmTheBackupAndChangesNothing() async {
        storedKey = "stale-key"
        encryption.recoverRecoveryKeyThrowableError = WrongKeyError()

        let confirmed = await controller.confirmCurrentBackupWithStoredKey()

        XCTAssertFalse(confirmed)
        XCTAssertFalse(encryption.disableRecoveryCalled)
        XCTAssertFalse(encryption.recoverAndFixBackupRecoveryKeyCalled)
        XCTAssertFalse(encryption.resetRecoveryKeyCalled)
        XCTAssertTrue(persisted.isEmpty)
    }

    func testRecoveryLeftIncompleteDoesNotConfirmTheBackup() async {
        storedKey = "stored-key"
        encryption.recoveryStateReturnValue = .incomplete

        let confirmed = await controller.confirmCurrentBackupWithStoredKey()

        XCTAssertFalse(confirmed)
    }
}
