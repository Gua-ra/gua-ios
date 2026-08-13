//
// Copyright 2023, 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import XCTest

@MainActor
class AppLockServiceTests: XCTestCase {
    var keychainController: KeychainController!
    var appSettings: AppSettings!
    var service: AppLockService!
    
    override func setUp() {
        AppSettings.resetAllSettings()
        appSettings = AppSettings()
        
        keychainController = KeychainController(service: .tests, accessGroup: InfoPlistReader.main.keychainAccessGroupIdentifier)
        keychainController.resetSecrets()
        
        service = AppLockService(keychainController: keychainController, appSettings: appSettings)
        service.disable()
    }
    
    override func tearDown() {
        AppSettings.resetAllSettings()
    }
    
    // MARK: - PIN Code
    
    func testValidPINCode() {
        // Given a service that hasn't been enabled.
        XCTAssertFalse(service.isEnabled, "The service shouldn't be enabled to begin with.")
        
        // When setting a PIN code.
        let pinCode = "2023" // Highly secure PIN that is rotated every 12 months.
        guard case .success = service.setupPINCode(pinCode) else {
            XCTFail("The PIN should be valid.")
            return
        }
        
        // Then service should be enabled and only the provided PIN should work to unlock the app.
        XCTAssertTrue(service.isEnabled, "The service should become enabled when setting a PIN.")
        XCTAssertTrue(service.unlock(with: pinCode), "The provided PIN code should work.")
        XCTAssertFalse(service.unlock(with: "2024"), "No other PIN code should work.")
        XCTAssertFalse(service.unlock(with: "1234"), "No other PIN code should work.")
        XCTAssertFalse(service.unlock(with: "9999"), "No other PIN code should work.")
    }
    
    func testWeakPINCode() {
        // Given a service that hasn't been enabled.
        XCTAssertFalse(service.isEnabled, "The service shouldn't be enabled to begin with.")
        
        // When setting a PIN code that is in the block list.
        let pinCode = appSettings.appLockPINCodeBlockList[0]
        let result = service.setupPINCode(pinCode)
        
        // Then the setup should fail and the service be left as disabled.
        guard case let .failure(error) = result else {
            XCTFail("The call should have failed.")
            return
        }
        XCTAssertEqual(error, .weakPIN, "The PIN should be rejected as weak.")
        XCTAssertFalse(service.isEnabled, "The service should remain disabled.")
    }
    
    func testShortPINCode() {
        // Given a service that hasn't been enabled.
        XCTAssertFalse(service.isEnabled, "The service shouldn't be enabled to begin with.")
        
        // When setting a PIN code that is too short
        let pinCode = "123"
        let result = service.setupPINCode(pinCode)
        
        // Then the setup should fail and the service be left as disabled.
        guard case let .failure(error) = result else {
            XCTFail("The call should have failed.")
            return
        }
        XCTAssertEqual(error, .invalidPIN, "The PIN should be rejected as invalid.")
        XCTAssertFalse(service.isEnabled, "The service should remain disabled.")
    }
    
    func testNonNumericPINCode() {
        // Given a service that hasn't been enabled.
        XCTAssertFalse(service.isEnabled, "The service shouldn't be enabled to begin with.")
        
        // When setting a PIN code that is too short
        let pinCode = "abcd"
        let result = service.setupPINCode(pinCode)
        
        // Then the setup should fail and the service be left as disabled.
        guard case let .failure(error) = result else {
            XCTFail("The call should have failed.")
            return
        }
        XCTAssertEqual(error, .invalidPIN, "The PIN should be rejected as invalid.")
        XCTAssertFalse(service.isEnabled, "The service should remain disabled.")
    }
    
    func testChangePINCode() {
        // Given a service that is already enabled with a PIN.
        let pinCode = "2023"
        let newPINCode = "2024"
        guard case .success = service.setupPINCode(pinCode) else {
            XCTFail("The PIN should be valid.")
            return
        }
        XCTAssertTrue(service.isEnabled, "The service should be enabled.")
        XCTAssertTrue(service.unlock(with: pinCode), "The initial PIN should work.")
        XCTAssertFalse(service.unlock(with: newPINCode), "The PIN we're about to set should not work.")
        
        // When updating the PIN code.
        guard case .success = service.setupPINCode(newPINCode) else {
            XCTFail("The PIN should be valid.")
            return
        }
        
        // Then the old code should not be accepted.
        XCTAssertTrue(service.isEnabled, "The service should remain enabled.")
        XCTAssertTrue(service.unlock(with: newPINCode), "The new PIN should work.")
        XCTAssertFalse(service.unlock(with: pinCode), "The original PIN should be rejected.")
    }
    
    func testInvalidChangePINCode() {
        // Given a service that is already enabled with a PIN.
        let pinCode = "2023"
        let invalidPIN = appSettings.appLockPINCodeBlockList[0]
        guard case .success = service.setupPINCode(pinCode) else {
            XCTFail("The PIN should be valid.")
            return
        }
        XCTAssertTrue(service.isEnabled, "The service should be enabled.")
        XCTAssertTrue(service.unlock(with: pinCode), "The initial PIN should work.")
        XCTAssertFalse(service.unlock(with: invalidPIN), "The PIN we're about to set should not work.")
        
        // When updating the PIN code that is in the block list.
        let result = service.setupPINCode(invalidPIN)
        
        // Then it should fail and nothing should change.
        guard case let .failure(error) = result else {
            XCTFail("The call should have failed.")
            return
        }
        XCTAssertEqual(error, .weakPIN, "The PIN should be rejected as weak.")
        XCTAssertTrue(service.isEnabled, "The service should remain enabled.")
        XCTAssertFalse(service.unlock(with: invalidPIN), "The rejected PIN shouldn't work.")
        XCTAssertTrue(service.unlock(with: pinCode), "The original PIN should continue to work.")
    }
    
    func testDisablePINCode() {
        // Given a service that is already enabled with a PIN.
        let pinCode = "2023"
        guard case .success = service.setupPINCode(pinCode) else {
            XCTFail("The PIN should be valid.")
            return
        }
        XCTAssertTrue(service.isEnabled, "The service should be enabled.")
        XCTAssertTrue(service.unlock(with: pinCode), "The initial PIN should work.")
        
        // When disabling the PIN code.
        service.disable()
        
        // Then the PIN code should be removed.
        XCTAssertFalse(service.isEnabled, "The service should no longer be enabled.")
        XCTAssertFalse(service.unlock(with: pinCode), "The initial PIN shouldn't work any more.")
    }
    
    // MARK: - Biometric Unlock
    
    func testEnableBiometricUnlock() async {
        // Given a service with the PIN code already set.
        let context = LAContextMock()
        context.biometryTypeValue = .touchID
        context.evaluatedPolicyDomainStateValue = Data("👆".utf8)
        service = AppLockService(keychainController: keychainController, appSettings: appSettings, context: context)
        guard case .success = service.setupPINCode("2023") else {
            XCTFail("The PIN should be valid.")
            return
        }
        XCTAssertTrue(service.isEnabled, "The service should be enabled.")
        XCTAssertEqual(service.biometryType, .touchID, "The biometry type should be in sync with the mock.")

        // When the user has opted out of biometric unlock.
        service.disableBiometricUnlock()
        XCTAssertFalse(service.biometricUnlockEnabled, "Biometric unlock should not be enabled.")
        XCTAssertFalse(service.biometricUnlockTrusted, "Biometric unlock should not be trusted.")

        // When enabling biometric unlock.
        guard case .success = service.enableBiometricUnlock() else {
            XCTFail("The biometric lock should enable.")
            return
        }
        context.evaluatePolicyReturnValue = true
        
        // Then the service should be unlockable with biometrics.
        XCTAssertEqual(service.biometryType, .touchID, "The biometry type should not change.")
        XCTAssertTrue(service.biometricUnlockEnabled, "Biometric unlock should now be enabled.")
        XCTAssertTrue(service.biometricUnlockTrusted, "Biometric unlock should now be trusted.")
        guard await service.unlockWithBiometrics() == .unlocked else {
            XCTFail("The biometric unlock should work.")
            return
        }
    }
    
    // MARK: - GUA FORK: Biometric unlock by default

    func testBiometricUnlockIsEnabledWithThePINCode() {
        // Given a device with biometrics available and no PIN code set.
        let context = LAContextMock()
        context.biometryTypeValue = .faceID
        context.evaluatedPolicyDomainStateValue = Data("😀".utf8)
        service = AppLockService(keychainController: keychainController, appSettings: appSettings, context: context)
        XCTAssertFalse(service.biometricUnlockEnabled, "Biometric unlock shouldn't be enabled without a PIN code.")

        // When setting a PIN code.
        guard case .success = service.setupPINCode("2023") else {
            XCTFail("The PIN should be valid.")
            return
        }

        // Then biometric unlock should be on without the user having to ask for it.
        XCTAssertTrue(service.biometricUnlockEnabled, "Biometric unlock should be enabled by default.")
        XCTAssertTrue(service.biometricUnlockTrusted, "Biometric unlock should be trusted.")
    }

    func testBiometricUnlockIsEnabledForAnExistingPINCode() {
        // Given a PIN code that was set on a device without biometrics.
        let pinOnlyContext = LAContextMock()
        pinOnlyContext.biometryTypeValue = .none
        pinOnlyContext.evaluatedPolicyDomainStateValue = nil
        service = AppLockService(keychainController: keychainController, appSettings: appSettings, context: pinOnlyContext)
        guard case .success = service.setupPINCode("2023") else {
            XCTFail("The PIN should be valid.")
            return
        }
        XCTAssertFalse(service.biometricUnlockEnabled, "Biometric unlock shouldn't be enabled without biometrics.")

        // When the app is next launched on a device that does have biometrics.
        let context = LAContextMock()
        context.biometryTypeValue = .faceID
        context.evaluatedPolicyDomainStateValue = Data("😀".utf8)
        service = AppLockService(keychainController: keychainController, appSettings: appSettings, context: context)
        service.applyBiometricUnlockDefault()

        // Then the existing PIN code should be upgraded to biometric unlock.
        XCTAssertTrue(service.biometricUnlockEnabled, "Biometric unlock should be enabled on launch.")
        XCTAssertTrue(service.biometricUnlockTrusted, "Biometric unlock should be trusted.")
    }

    func testBiometricUnlockOptOutIsRemembered() {
        // Given a service where the user has turned biometric unlock off.
        let context = LAContextMock()
        context.biometryTypeValue = .faceID
        context.evaluatedPolicyDomainStateValue = Data("😀".utf8)
        service = AppLockService(keychainController: keychainController, appSettings: appSettings, context: context)
        guard case .success = service.setupPINCode("2023") else {
            XCTFail("The PIN should be valid.")
            return
        }
        service.disableBiometricUnlock()
        XCTAssertFalse(service.biometricUnlockEnabled, "Biometric unlock should be disabled.")

        // When the app is next launched.
        service = AppLockService(keychainController: keychainController, appSettings: appSettings, context: context)

        // Then the default shouldn't undo the user's choice.
        XCTAssertFalse(service.biometricUnlockEnabled, "Biometric unlock should stay disabled.")

        // And turning it back on should stick.
        guard case .success = service.enableBiometricUnlock() else {
            XCTFail("The biometric lock should enable.")
            return
        }
        service = AppLockService(keychainController: keychainController, appSettings: appSettings, context: context)
        XCTAssertTrue(service.biometricUnlockEnabled, "Biometric unlock should stay enabled.")
    }

    func testRemovingThePINCodeForgetsTheOptOut() {
        // Given a service where the user turned biometric unlock off and then removed their PIN.
        let context = LAContextMock()
        context.biometryTypeValue = .faceID
        context.evaluatedPolicyDomainStateValue = Data("😀".utf8)
        service = AppLockService(keychainController: keychainController, appSettings: appSettings, context: context)
        guard case .success = service.setupPINCode("2023") else {
            XCTFail("The PIN should be valid.")
            return
        }
        service.disableBiometricUnlock()
        service.disable()

        // When setting the app lock up again from scratch.
        guard case .success = service.setupPINCode("2023") else {
            XCTFail("The PIN should be valid.")
            return
        }

        // Then it should start from the biometrics-on default again.
        XCTAssertTrue(service.biometricUnlockEnabled, "Biometric unlock should be enabled by default.")
    }

    func testBiometricUnlockTrust() {
        // Given a service with the PIN code already set.
        let context = LAContextMock()
        context.biometryTypeValue = .touchID
        context.evaluatedPolicyDomainStateValue = Data("👆".utf8)
        service = AppLockService(keychainController: keychainController, appSettings: appSettings, context: context)
        let pinCode = "2023"
        guard case .success = service.setupPINCode(pinCode) else {
            XCTFail("The PIN should be valid.")
            return
        }
        guard case .success = service.enableBiometricUnlock() else {
            XCTFail("The biometric lock should enable.")
            return
        }
        XCTAssertTrue(service.isEnabled, "The service should be enabled.")
        XCTAssertEqual(service.biometryType, .touchID, "The biometry type should be in sync with the mock.")
        XCTAssertTrue(service.biometricUnlockEnabled, "Biometric unlock should be enabled.")
        XCTAssertTrue(service.biometricUnlockTrusted, "Biometric unlock should be trusted.")
        
        // When the user changes biometric data.
        context.evaluatedPolicyDomainStateValue = Data("👈".utf8)
        
        // Then biometric lock should remain enabled but untrusted.
        XCTAssertTrue(service.isEnabled, "The service should remain enabled.")
        XCTAssertEqual(service.biometryType, .touchID, "The biometry type should not change.")
        XCTAssertTrue(service.biometricUnlockEnabled, "Biometric unlock should remain enabled.")
        XCTAssertFalse(service.biometricUnlockTrusted, "Biometric unlock should no longer be trusted.")
        
        // When the user confirms their PIN code.
        XCTAssertTrue(service.unlock(with: pinCode), "The PIN code should be accepted")
        
        // Then the biometric lock should once again be trusted.
        XCTAssertTrue(service.isEnabled, "The service should remain enabled.")
        XCTAssertEqual(service.biometryType, .touchID, "The biometry type should not change.")
        XCTAssertTrue(service.biometricUnlockEnabled, "Biometric unlock should remain enabled.")
        XCTAssertTrue(service.biometricUnlockTrusted, "Biometric unlock should once again be trusted.")
    }
    
    func testDisableBiometricUnlock() {
        // Given a service with the PIN code already set.
        let context = LAContextMock()
        context.biometryTypeValue = .touchID
        context.evaluatedPolicyDomainStateValue = Data("👆".utf8)
        service = AppLockService(keychainController: keychainController, appSettings: appSettings, context: context)
        guard case .success = service.setupPINCode("2023") else {
            XCTFail("The PIN should be valid.")
            return
        }
        guard case .success = service.enableBiometricUnlock() else {
            XCTFail("The biometric lock should enable.")
            return
        }
        XCTAssertTrue(service.isEnabled, "The service should be enabled.")
        XCTAssertEqual(service.biometryType, .touchID, "The biometry type should be in sync with the mock.")
        XCTAssertTrue(service.biometricUnlockEnabled, "Biometric unlock should be enabled.")
        XCTAssertTrue(service.biometricUnlockTrusted, "Biometric unlock should be trusted.")
        
        // When disabling biometric unlock.
        service.disableBiometricUnlock()
        
        // Then only PIN unlock should remain enabled.
        XCTAssertTrue(service.isEnabled, "The service should remain enabled.")
        XCTAssertEqual(service.biometryType, .touchID, "The biometry type should not change.")
        XCTAssertFalse(service.biometricUnlockEnabled, "Biometric unlock should become disabled.")
        XCTAssertFalse(service.biometricUnlockTrusted, "Biometric unlock should no longer be trusted.")
    }
    
    func testDisablePINWithBiometricUnlock() {
        // Given a service with the PIN code already set.
        let context = LAContextMock()
        context.biometryTypeValue = .touchID
        context.evaluatedPolicyDomainStateValue = Data("👆".utf8)
        service = AppLockService(keychainController: keychainController, appSettings: appSettings, context: context)
        guard case .success = service.setupPINCode("2023") else {
            XCTFail("The PIN should be valid.")
            return
        }
        guard case .success = service.enableBiometricUnlock() else {
            XCTFail("The biometric lock should enable.")
            return
        }
        XCTAssertTrue(service.isEnabled, "The service should be enabled.")
        XCTAssertTrue(service.biometricUnlockEnabled, "Biometric unlock should be enabled.")
        XCTAssertTrue(service.biometricUnlockTrusted, "Biometric unlock should be trusted.")
        
        // When disabling the PIN lock.
        service.disable()
        
        // Then both PIN and biometric unlock should be disabled.
        XCTAssertFalse(service.isEnabled, "The service should remain enabled.")
        XCTAssertFalse(service.biometricUnlockEnabled, "Biometric unlock should become disabled.")
        XCTAssertFalse(service.biometricUnlockTrusted, "Biometric unlock should no longer be trusted.")
    }
    
    // MARK: - Attempt failures
    
    func testResetAttemptsOnUnlock() {
        // Given a service that is enabled and has failed unlock attempts.
        let pinCode = "2023"
        guard case .success = service.setupPINCode(pinCode) else {
            XCTFail("The PIN should be valid.")
            return
        }
        appSettings.appLockNumberOfPINAttempts = 2
        XCTAssertEqual(appSettings.appLockNumberOfPINAttempts, 2, "The initial conditions should be stored.")
        XCTAssertTrue(service.isEnabled, "The service should be enabled.")
        
        // When unlocking the service
        XCTAssertTrue(service.unlock(with: pinCode), "The PIN should work.")
        
        // Then the attempts counts should both be reset.
        XCTAssertEqual(appSettings.appLockNumberOfPINAttempts, 0, "The PIN attempts should be reset.")
    }
    
    func testResetAttemptsOnDisable() {
        // Given a service that is enabled and has failed unlock attempts.
        let pinCode = "2023"
        guard case .success = service.setupPINCode(pinCode) else {
            XCTFail("The PIN should be valid.")
            return
        }
        appSettings.appLockNumberOfPINAttempts = 2
        XCTAssertEqual(appSettings.appLockNumberOfPINAttempts, 2, "The initial conditions should be stored.")
        XCTAssertTrue(service.isEnabled, "The service should be enabled.")
        
        // When disabling the service
        service.disable()
        XCTAssertFalse(service.isEnabled, "The service should be disabled.")
        
        // Then the attempts counts should both be reset.
        XCTAssertEqual(appSettings.appLockNumberOfPINAttempts, 0, "The PIN attempts should be reset.")
    }
}
