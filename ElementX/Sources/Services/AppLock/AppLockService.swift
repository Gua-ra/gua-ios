//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import LocalAuthentication

/// The service responsible for locking and unlocking the app.
class AppLockService: AppLockServiceProtocol {
    private let keychainController: KeychainControllerProtocol
    private let appSettings: AppSettings
    private let context: LAContext
    
    private let timer: AppLockTimer
    /// Only use Biometrics to unlock the app, we want to fall back to the App Lock PIN, not the device's passcode.
    private let unlockPolicy: LAPolicy = .deviceOwnerAuthenticationWithBiometrics
    /// Use biometrics *or* the device's passcode to verify the device owner. Available regardless of whether biometrics are enrolled.
    ///
    /// **Note:** Verifying the device owner is used to gate sensitive actions, it isn't related to unlocking the app.
    /// Maybe we should rename this service in the future.
    private let deviceOwnerPolicy: LAPolicy = .deviceOwnerAuthentication
    
    var isMandatory: Bool {
        appSettings.appLockIsMandatory
    }
    
    var isEnabled: Bool {
        do {
            return try keychainController.containsPINCode()
        } catch {
            MXLog.error("Keychain access error: \(error)")
            MXLog.error("Locking the app.")
            return true
        }
    }
    
    private var isEnabledSubject: PassthroughSubject<Bool, Never> = .init()
    var isEnabledPublisher: AnyPublisher<Bool, Never> {
        isEnabledSubject.eraseToAnyPublisher()
    }
    
    var biometryType: LABiometryType {
        guard context.biometricStateHash != nil else { return .none }
        return context.biometryType
    }
    
    var biometricUnlockEnabled: Bool {
        keychainController.containsPINCodeBiometricState()
    }
    
    var biometricUnlockTrusted: Bool {
        guard let state = keychainController.pinCodeBiometricState() else { return false }
        return state == context.biometricStateHash
    }
    
    var numberOfPINAttempts: AnyPublisher<Int, Never> {
        appSettings.appLockNumberOfPINAttemptsPublisher
    }
    
    init(keychainController: KeychainControllerProtocol, appSettings: AppSettings, context: LAContext = .init()) {
        self.keychainController = keychainController
        self.appSettings = appSettings
        self.context = context
        timer = AppLockTimer(gracePeriod: appSettings.appLockGracePeriod)
    }
    
    func setupPINCode(_ pinCode: String) -> Result<Void, AppLockServiceError> {
        let result = validate(pinCode)
        guard case .success = result else { return result }
        
        do {
            try keychainController.setPINCode(pinCode)
            isEnabledSubject.send(true)
            applyBiometricUnlockDefault()
            return .success(())
        } catch {
            MXLog.error("Keychain access error: \(error)")
            return .failure(.keychainError)
        }
    }
    
    func validate(_ pinCode: String) -> Result<Void, AppLockServiceError> {
        guard pinCode.count == 4, pinCode.allSatisfy(\.isNumber) else { return .failure(.invalidPIN) }
        guard !appSettings.appLockPINCodeBlockList.contains(pinCode) else { return .failure(.weakPIN) }
        return .success(())
    }
    
    func enableBiometricUnlock() -> Result<Void, AppLockServiceError> {
        guard isEnabled else { return .failure(.pinNotSet) }
        guard let state = context.biometricStateHash else { return .failure(.biometricUnlockNotSupported) }
        
        do {
            try keychainController.setPINCodeBiometricState(state)
            appSettings.appLockBiometricUnlockOptOut = false
            return .success(())
        } catch {
            MXLog.error("Keychain access error: \(error)")
            return .failure(.keychainError)
        }
    }
    
    func disableBiometricUnlock() {
        keychainController.removePINCodeBiometricState()
        // GUA FORK: remember that this was the user's choice, so that the default below
        // doesn't turn biometric unlock straight back on the next time the app launches.
        appSettings.appLockBiometricUnlockOptOut = true
    }
    
    /// GUA FORK: turns biometric unlock on by default so that Face ID/Touch ID is the way into
    /// the app and the PIN code is only the fallback. Does nothing when the user has opted out,
    /// when the device has no enrolled biometrics, or when there's no PIN code to fall back to.
    ///
    /// Called when setting a PIN code, and again at launch so that people who already had a PIN
    /// code get biometric unlock when they update the app.
    func applyBiometricUnlockDefault() {
        // The device check comes first: it is the cheap one, and it keeps this off the keychain
        // entirely on a device that could never use biometrics anyway.
        guard biometryType != .none,
              !appSettings.appLockBiometricUnlockOptOut,
              isEnabled,
              !biometricUnlockEnabled else { return }
        
        if case let .failure(error) = enableBiometricUnlock() {
            MXLog.warning("Not enabling biometric unlock by default: \(error)")
        }
    }
    
    func disable() {
        keychainController.removePINCode()
        keychainController.removePINCodeBiometricState()
        appSettings.appLockNumberOfPINAttempts = 0
        // GUA FORK: removing the PIN code tears the feature down completely, so forget the
        // opt-out too - setting a PIN up again starts from the biometrics-on default.
        appSettings.appLockBiometricUnlockOptOut = false
        isEnabledSubject.send(false)
    }
    
    func applicationDidEnterBackground() {
        timer.applicationDidEnterBackground()
    }
    
    func computeNeedsUnlock(didBecomeActiveAt date: Date) -> Bool {
        timer.computeLockState(didBecomeActiveAt: date)
    }
    
    func unlock(with pinCode: String) -> Bool {
        guard pinCode == keychainController.pinCode() else {
            MXLog.warning("Wrong PIN entered.")
            appSettings.appLockNumberOfPINAttempts += 1
            return false
        }
        
        if biometricUnlockEnabled, !biometricUnlockTrusted {
            MXLog.info("Fixing trust for biometric unlock.")
            _ = enableBiometricUnlock()
        }
        
        completeUnlock()
        return true
    }
    
    func unlockWithBiometrics() async -> AppLockServiceBiometricResult {
        guard biometryType != .none, biometricUnlockEnabled else {
            MXLog.error("Biometric unlock not setup.")
            return .failed
        }
        
        guard biometricUnlockTrusted else {
            MXLog.error("Biometrics have changed. PIN should be shown.")
            return .failed
        }
        
        do {
            let context = unlockContext()
            guard try await context.evaluatePolicy(unlockPolicy, localizedReason: L10n.screenAppLockBiometricUnlockReasonIos) else {
                MXLog.warning("\(context.biometryType) failed without error.")
                return .failed
            }
            completeUnlock()
            return .unlocked
        } catch LAError.systemCancel {
            MXLog.error("\(context.biometryType) failed: The system cancelled.")
            return .interrupted
        } catch {
            MXLog.error("\(context.biometryType) failed: \(error)")
            return .failed
        }
    }
    
    func verifyDeviceOwner(reason: String) async -> AppLockDeviceOwnerResult {
        let context = verificationContext()
        
        var error: NSError?
        guard context.canEvaluatePolicy(deviceOwnerPolicy, error: &error) else {
            MXLog.warning("Device owner verification unavailable: \(String(describing: error))")
            return isEnabled ? .appLockPINRequired : .unavailable
        }
        
        do {
            guard try await context.evaluatePolicy(deviceOwnerPolicy, localizedReason: reason) else {
                MXLog.warning("Device owner verification completed without success.")
                return .unverified
            }
            return .verified
        } catch LAError.userCancel, LAError.systemCancel {
            MXLog.info("Device owner verification was cancelled.")
            return .cancelled
        } catch {
            MXLog.warning("Device owner verification failed: \(error)")
            return .error
        }
    }
    
    // MARK: - Private
    
    /// Creates a context specifically for unlocking the app. The titles are customised,
    /// and the fresh context ensures that the user is promoted to unlock based on
    /// `timer.gracePeriod` rather than any system to defined grace period.
    private func unlockContext() -> LAContext {
        // Keep using the injected context for tests etc.
        guard type(of: context) == LAContext.self else { return context }
        
        let context = LAContext()
        context.localizedFallbackTitle = L10n.actionEnterPin
        return context
    }
    
    /// Creates a fresh context for device owner verification so the user is always prompted.
    private func verificationContext() -> LAContext {
        // Keep using the injected context for tests etc.
        type(of: context) == LAContext.self ? LAContext() : context
    }
    
    /// Shared logic for completing an unlock via a PIN or biometrics.
    private func completeUnlock() {
        timer.registerUnlock()
        appSettings.appLockNumberOfPINAttempts = 0
    }
}

nonisolated extension LAContext {
    /// A hash of the enrolled biometric data that changes whenever biometrics are added or removed.
    /// Unlike the deprecated `evaluatedPolicyDomainState`, this doesn't need `canEvaluatePolicy` to be called first.
    @objc var biometricStateHash: Data? {
        domainState.biometry.stateHash
    }
}
