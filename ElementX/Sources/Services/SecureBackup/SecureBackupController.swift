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
        
    /// GUA FORK: repairs key storage for an account stuck at `.incomplete`.
    ///
    /// Deliberately NOT `recoverAndFixBackup`, despite the repair-shaped name. Its fix branch
    /// deletes the server-side key backup and creates a new one, so any history whose room keys
    /// live only in that backup is destroyed. `recover` just opens secret storage and pulls the
    /// secrets this device is missing, which is the actual meaning of `.incomplete`.
    func repairRecovery(with key: String) async -> Result<Void, SecureBackupControllerError> {
        do {
            MXLog.info("Repairing recovery from the stored key")
            try await encryption.recover(recoveryKey: key)
            return .success(())
        } catch {
            MXLog.error("Failed repairing recovery with error: \(error)")
            return .failure(.failedConfirmingRecoveryKey)
        }
    }

    /// GUA FORK: repairs an account that is `.incomplete` with NO recovery key available.
    ///
    /// This is the state every account damaged by the old silent bootstrap is in, so it is the
    /// one that decides whether existing users can be fixed by an app update at all.
    ///
    /// `enableRecovery` is the only safe call here. It never deletes a key backup and never
    /// touches the cross-signing identity, so no contact sees a "security details changed"
    /// warning, and if a server backup blocks it, it fails with `BackupExistsOnServer` before
    /// mutating anything. `resetRecoveryKey` cannot help: it builds new storage without making
    /// any missing secret locally available, which is the only thing `.incomplete` measures.
    ///
    /// It fixes the case where cross-signing is intact but backup was never enabled. If the
    /// private cross-signing keys themselves are missing, nothing here can help and the account
    /// needs another signed-in device; we leave it alone rather than reset the identity.
    func provisionRecoveryWithoutKey() async -> Result<String, SecureBackupControllerError> {
        do {
            MXLog.info("Provisioning recovery for an incomplete account with no stored key")
            return try await .success(enableRecoveryReturningKey())
        } catch RecoveryError.BackupExistsOnServer {
            // The common case for accounts the old bootstrap damaged: server storage and a key
            // backup both exist, but this device is missing the secrets and no key survives.
            // enableRecovery refuses to overwrite a backup, so on its own it can never get an
            // account out of .incomplete. This is why the previous attempt changed nothing.
            MXLog.info("A key backup exists on the server; deciding whether it is still reachable.")

            // If another signed-in device exists it can hand the secrets over, which repairs
            // this for free and keeps the backup. Never destroy anything while that is possible.
            if await (try? encryption.hasDevicesToVerifyAgainst()) == true {
                MXLog.warning("Another device can supply the secrets; leaving key storage alone.")
                return .failure(.failedGeneratingRecoveryKey)
            }

            // No key anywhere and no other device, so nothing can ever decrypt that backup
            // again. Keeping it preserves only a permanently broken account, so replace it.
            // This does not touch the cross-signing identity, so no contact is warned.
            MXLog.warning("Backup is unreachable by any key or device; replacing key storage.")
            do {
                try await encryption.disableRecovery()
                return try await .success(enableRecoveryReturningKey())
            } catch {
                MXLog.error("Failed replacing unreachable key storage: \(error)")
                return .failure(.failedGeneratingRecoveryKey)
            }
        } catch {
            MXLog.warning("Could not provision recovery without a key: \(error)")
            return .failure(.failedGeneratingRecoveryKey)
        }
    }

    private func enableRecoveryReturningKey() async throws -> String {
        try await encryption.enableRecovery(waitForBackupsToUpload: false,
                                            passphrase: nil,
                                            progressListener: SDKListener { _ in })
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
