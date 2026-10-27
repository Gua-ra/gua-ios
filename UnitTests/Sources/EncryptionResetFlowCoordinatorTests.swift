//
// Copyright Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import XCTest

@MainActor
class EncryptionResetFlowCoordinatorTests: XCTestCase {
    private var recoveryState: CurrentValueSubject<SecureBackupRecoveryState, Never>!
    private var keyBackupState: CurrentValueSubject<SecureBackupKeyBackupState, Never>!
    private var secureBackupController: SecureBackupControllerMock!
    private var flowCoordinator: EncryptionResetFlowCoordinator!
    private var toasts: [String] = []
    private var actions: [EncryptionResetFlowCoordinatorAction] = []
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        recoveryState = .init(.incomplete)
        keyBackupState = .init(.unknown)
        secureBackupController = SecureBackupControllerMock(.init())
        secureBackupController.underlyingRecoveryState = .init(recoveryState)
        secureBackupController.underlyingKeyBackupState = .init(keyBackupState)

        let clientProxy = ClientProxyMock(.init(userID: "@alice:example.org"))
        clientProxy.secureBackupController = secureBackupController
        clientProxy.sessionVerificationController = SessionVerificationControllerProxyMock.configureMock()

        toasts = []
        let userIndicatorController = UserIndicatorControllerMock.default
        userIndicatorController.submitIndicatorDelayClosure = { [weak self] indicator, _ in
            self?.toasts.append(indicator.title)
        }

        flowCoordinator = EncryptionResetFlowCoordinator(parameters: .init(userSession: UserSessionMock(.init(clientProxy: clientProxy)),
                                                                           appSettings: ServiceLocator.shared.settings,
                                                                           userIndicatorController: userIndicatorController,
                                                                           navigationStackCoordinator: NavigationStackCoordinator(),
                                                                           windowManger: WindowManagerMock()))

        actions = []
        cancellables = []
        flowCoordinator.actionsPublisher
            .sink { [weak self] action in self?.actions.append(action) }
            .store(in: &cancellables)
    }

    func testKeysArrivingOnADeviceWithoutABackupIsASuccess() async {
        flowCoordinator.presentRecoveryFromOtherDevice()
        // The other device hands over the identity and the current backup key.
        keyBackupState.send(.enabled)
        recoveryState.send(.enabled)

        await flowCoordinator.finishRecoveryFromOtherDevice()

        XCTAssertFalse(secureBackupController.confirmCurrentBackupWithStoredKeyCalled)
        XCTAssertEqual(toasts.last, L10n.commonSuccess)
        XCTAssertEqual(actions, [.resetComplete])
    }

    func testABackupHeldBeforeVerificationAndConfirmedIsASuccess() async {
        keyBackupState.send(.enabled)
        secureBackupController.confirmCurrentBackupWithStoredKeyReturnValue = true

        flowCoordinator.presentRecoveryFromOtherDevice()
        recoveryState.send(.enabled)
        await flowCoordinator.finishRecoveryFromOtherDevice()

        XCTAssertEqual(secureBackupController.confirmCurrentBackupWithStoredKeyCallsCount, 1)
        XCTAssertEqual(toasts.last, L10n.commonSuccess)
        XCTAssertEqual(actions, [.resetComplete])
    }

    func testABackupHeldBeforeVerificationThatCannotBeConfirmedEndsTheFlowWithoutASuccess() async {
        keyBackupState.send(.enabled)
        secureBackupController.confirmCurrentBackupWithStoredKeyReturnValue = false

        flowCoordinator.presentRecoveryFromOtherDevice()
        recoveryState.send(.enabled)
        await flowCoordinator.finishRecoveryFromOtherDevice()

        XCTAssertEqual(secureBackupController.confirmCurrentBackupWithStoredKeyCallsCount, 1)
        XCTAssertEqual(toasts.last, UntranslatedL10n.guaEncryptionRecoverFromOtherDeviceBackupUnconfirmed)
        XCTAssertFalse(toasts.contains(L10n.commonSuccess))
        XCTAssertEqual(actions, [.resetComplete])
    }

    func testEachAttemptJudgesTheBackupHeldWhenItStarted() async {
        keyBackupState.send(.enabled)
        flowCoordinator.presentRecoveryFromOtherDevice()

        keyBackupState.send(.unknown)
        flowCoordinator.presentRecoveryFromOtherDevice()
        keyBackupState.send(.enabled)
        recoveryState.send(.enabled)
        await flowCoordinator.finishRecoveryFromOtherDevice()

        XCTAssertFalse(secureBackupController.confirmCurrentBackupWithStoredKeyCalled)
        XCTAssertEqual(toasts.last, L10n.commonSuccess)
    }

    func testRecoveryNotEnabledMeansTheKeysDidNotArrive() {
        XCTAssertEqual(EncryptionResetFlowCoordinator.recoveryFromOtherDeviceOutcome(recoveryEnabled: false, backupConfirmed: true),
                       .keysDidNotArrive)
        XCTAssertEqual(EncryptionResetFlowCoordinator.recoveryFromOtherDeviceOutcome(recoveryEnabled: false, backupConfirmed: false),
                       .keysDidNotArrive)
    }
}
