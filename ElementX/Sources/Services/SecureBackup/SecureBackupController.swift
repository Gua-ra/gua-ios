//
// Copyright 2023, 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import MatrixRustSDK

class SecureBackupController: SecureBackupControllerProtocol {
    private let encryption: Encryption
    
    private let recoveryStateSubject = CurrentValueSubject<SecureBackupRecoveryState, Never>(.unknown)
    private let keyBackupStateSubject = CurrentValueSubject<SecureBackupKeyBackupState, Never>(.unknown)
    
    // periphery:ignore - retaining purpose
    private var backupStateListenerTaskHandle: TaskHandle?
    // periphery:ignore - retaining purpose
    private var recoveryStateListenerTaskHandle: TaskHandle?
    
    // periphery:ignore - auto cancels when reassigned
    /// Used to dedupe remote backup state requests
    @CancellableTask private var remoteBackupStateTask: Task<Void, Error>?
    
    var recoveryState: CurrentValuePublisher<SecureBackupRecoveryState, Never> {
        recoveryStateSubject.asCurrentValuePublisher()
    }
    
    var keyBackupState: CurrentValuePublisher<SecureBackupKeyBackupState, Never> {
        keyBackupStateSubject.asCurrentValuePublisher()
    }
    
    init(encryption: Encryption) {
        self.encryption = encryption
        
        backupStateListenerTaskHandle = encryption.backupStateListener(listener: SDKListener { [weak self] state in
            guard let self else { return }
            
            switch state {
            case .unknown:
                keyBackupStateSubject.send(.unknown)
            case .creating:
                keyBackupStateSubject.send(.enabling)
            case .enabling:
                keyBackupStateSubject.send(.enabling)
            case .resuming:
                keyBackupStateSubject.send(.enabled)
            case .enabled:
                keyBackupStateSubject.send(.enabled)
            case .downloading:
                keyBackupStateSubject.send(.enabled)
            case .disabling:
                keyBackupStateSubject.send(.disabling)
            }
            
            MXLog.info("Key backup state changed to: \(state), setting local state to \(keyBackupStateSubject.value)")
            
            if case .unknown = state {
                updateBackupStateFromRemote()
            }
        })
        
        recoveryStateListenerTaskHandle = encryption.recoveryStateListener(listener: SDKListener { [weak self] state in
            guard let self else { return }
            
            switch state {
            case .unknown:
                recoveryStateSubject.send(.unknown)
            case .enabled:
                recoveryStateSubject.send(.enabled)
            case .disabled:
                recoveryStateSubject.send(.disabled)
            case .incomplete:
                recoveryStateSubject.send(.incomplete)
            }
            
            MXLog.info("Recovery state changed to: \(state), setting local state to \(recoveryStateSubject.value)")
        })
        
        updateBackupStateFromRemote()
    }
    
    func enable() async -> Result<Void, SecureBackupControllerError> {
        MXLog.info("Enabling secure backup")
        
        do {
            try await encryption.enableBackups()
        } catch {
            MXLog.error("Failed enabling secure backup with error: \(error)")
            
            return .failure(.failedEnablingBackup)
        }
        
        return .success(())
    }
    
    func disable() async -> Result<Void, SecureBackupControllerError> {
        MXLog.info("Disabling secure backup")
        
        do {
            try await encryption.disableRecovery()
        } catch {
            MXLog.error("Failed disabling secure backup with error: \(error)")
            return .failure(.failedDisablingBackup)
        }
        
        return .success(())
    }
    
    /// GUA FORK: waits for `recoveryState` to report something other than `.unknown`.
    ///
    /// The subject starts at `.unknown` and only settles once the SDK has told us where the
    /// account stands. Branching before then silently picks the wrong path, which is how key
    /// storage ended up half-built: a fresh account read `.unknown`, failed the `== .disabled`
    /// test, and rotated the storage key instead of running the full bootstrap.
    func settledRecoveryState(timeout: Duration = .seconds(10)) async -> SecureBackupRecoveryState {
        if recoveryState.value != .unknown {
            return recoveryState.value
        }

        return await withTaskGroup(of: SecureBackupRecoveryState.self) { group in
            group.addTask { [recoveryState] in
                for await state in recoveryState.values where state != .unknown {
                    return state
                }
                return .unknown
            }

            group.addTask {
                try? await Task.sleep(for: timeout)
                return .unknown
            }

            let state = await group.next() ?? .unknown
            group.cancelAll()
            return state
        }
    }

    func generateRecoveryKey() async -> Result<String, SecureBackupControllerError> {
        do {
            let state = await settledRecoveryState()

            // GUA FORK: `.unknown` here means the SDK never reported, i.e. the wait timed out.
            // Resetting on it would rotate the storage key while the account state is still
            // unknown and orphan an existing backup, which is the exact failure this method was
            // changed to avoid. Refuse instead; the caller retries on the next launch.
            guard state != .unknown else {
                MXLog.warning("Recovery state never settled, refusing to touch key storage.")
                return .failure(.failedGeneratingRecoveryKey)
            }

            guard state == .disabled else {
                MXLog.info("Resetting recovery key")
                
                let key = try await encryption.resetRecoveryKey()
                return .success(key)
            }
            
            MXLog.info("Enabling recovery")
            
            var keyUploadErrored = false
            let recoveryKey = try await encryption.enableRecovery(waitForBackupsToUpload: false, passphrase: nil, progressListener: SDKListener { [weak self] state in
                guard let self else { return }
                
                switch state {
                case .starting, .creatingBackup, .creatingRecoveryKey, .backingUp:
                    recoveryStateSubject.send(.settingUp)
                case .done:
                    recoveryStateSubject.send(.enabled)
                case .roomKeyUploadError:
                    MXLog.error("Failed enabling recovery: room key upload error")
                    keyUploadErrored = true
                }
            })
            
            return keyUploadErrored ? .failure(.failedGeneratingRecoveryKey) : .success(recoveryKey)
        } catch {
            MXLog.error("Failed generating recovery key with error: \(error)")
            
            return .failure(.failedGeneratingRecoveryKey)
        }
    }
    
    func confirmRecoveryKey(_ key: String) async -> Result<Void, SecureBackupControllerError> {
        do {
            MXLog.info("Confirming recovery key")
            try await encryption.recover(recoveryKey: key)
            return .success(())
        } catch {
            MXLog.info("Failed confirming recovery key with error: \(error)")
            return .failure(.failedConfirmingRecoveryKey)
        }
    }
        
    /// GUA FORK: repairs a half-built key storage rather than merely unlocking a healthy one.
    ///
    /// `recover` assumes secret storage is consistent and just needs the key. The state we
    /// actually hit is `.incomplete`: storage exists but is missing secrets. `recoverAndFixBackup`
    /// is the SDK call documented to reconcile that, so self-heal uses this rather than
    /// `confirmRecoveryKey`.
    func repairRecovery(with key: String) async -> Result<Void, SecureBackupControllerError> {
        do {
            MXLog.info("Repairing recovery from the stored key")
            try await encryption.recoverAndFixBackup(recoveryKey: key)
            return .success(())
        } catch {
            MXLog.error("Failed repairing recovery with error: \(error)")
            return .failure(.failedConfirmingRecoveryKey)
        }
    }

    func waitForKeyBackupUpload(uploadStateSubject: CurrentValueSubject<SecureBackupSteadyState, Never>) async -> Result<Void, SecureBackupControllerError> {
        do {
            MXLog.info("Waiting for backup upload steady state")
            try await encryption.waitForBackupUploadSteadyState(progressListener: SDKListener { state in
                let uploadState: SecureBackupSteadyState = switch state {
                case .waiting: .waiting
                case .uploading(let backedUpCount, let totalCount): .uploading(uploadedKeyCount: Int(backedUpCount), totalKeyCount: Int(totalCount))
                case .error: .error
                case .done: .done
                }
                
                uploadStateSubject.send(uploadState)
            })
            return .success(())
        } catch let error as SteadyStateError {
            MXLog.error("Failed waiting for backup upload steady state with error: \(error)")
            
            switch error {
            case .BackupDisabled:
                MXLog.error("Key backup disabled, continuing logout.")
                return .success(())
            case .Connection, .Lagged:
                MXLog.error("Key backup upload failure: \(error)")
                return .failure(.failedUploadingForBackup)
            }
        } catch {
            MXLog.error("Unknown key backup upload failure")
            return .failure(.failedUploadingForBackup)
        }
    }
    
    // MARK: - Private
    
    private func updateBackupStateFromRemote(retry: Bool = true) {
        remoteBackupStateTask = Task {
            do {
                MXLog.info("Checking if backup exists on the server")
                let backupExists = try await self.encryption.backupExistsOnServer()
                
                if Task.isCancelled {
                    return
                }
                
                if !backupExists {
                    keyBackupStateSubject.send(.unknown)
                }
            } catch {
                MXLog.error("Failed retrieving remote backup state with error: \(error)")
                
                if retry {
                    updateBackupStateFromRemote(retry: false)
                }
            }
        }
    }
}
