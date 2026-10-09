//
// Copyright Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import XCTest

@MainActor
class EncryptionResetFlowCoordinatorTests: XCTestCase {
    func testBackupOnWhileNoLongerSignedHoldsADeletedBackupKey() {
        XCTAssertTrue(EncryptionResetFlowCoordinator.holdsDeletedBackupKey(keyBackupState: .enabled, verificationState: .unverified))
    }

    func testFreshDeviceWithoutBackupDoesNotHoldADeletedBackupKey() {
        XCTAssertFalse(EncryptionResetFlowCoordinator.holdsDeletedBackupKey(keyBackupState: .unknown, verificationState: .unverified))
    }

    func testSignedDeviceWithBackupDoesNotHoldADeletedBackupKey() {
        XCTAssertFalse(EncryptionResetFlowCoordinator.holdsDeletedBackupKey(keyBackupState: .enabled, verificationState: .verified))
        XCTAssertFalse(EncryptionResetFlowCoordinator.holdsDeletedBackupKey(keyBackupState: .enabled, verificationState: .unknown))
    }

    func testRecoveryEnabledOnADeviceWithADeletedBackupKeyIsNotASuccess() {
        XCTAssertEqual(EncryptionResetFlowCoordinator.recoveryFromOtherDeviceOutcome(recoveryEnabled: true, holdsDeletedBackupKey: true),
                       .backupNotRestored)
    }

    func testRecoveryEnabledOnADeviceWithoutABackupKeyIsASuccess() {
        XCTAssertEqual(EncryptionResetFlowCoordinator.recoveryFromOtherDeviceOutcome(recoveryEnabled: true, holdsDeletedBackupKey: false),
                       .recovered)
    }

    func testRecoveryNotEnabledMeansTheKeysDidNotArrive() {
        XCTAssertEqual(EncryptionResetFlowCoordinator.recoveryFromOtherDeviceOutcome(recoveryEnabled: false, holdsDeletedBackupKey: false),
                       .keysDidNotArrive)
        XCTAssertEqual(EncryptionResetFlowCoordinator.recoveryFromOtherDeviceOutcome(recoveryEnabled: false, holdsDeletedBackupKey: true),
                       .keysDidNotArrive)
    }
}
