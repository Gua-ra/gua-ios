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
                MXLog.warning("GUA-KEYSTORE: recovery state never settled, refusing to act.")
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
            MXLog.info("GUA-KEYSTORE: enableRecovery on an incomplete account.")
            return try await .success(enableRecoveryReturningKey())
        } catch RecoveryError.BackupExistsOnServer {
            // The common case for accounts the old bootstrap damaged: server storage and a key
            // backup both exist, but this device is missing the secrets and no key survives.
            // enableRecovery refuses to overwrite a backup, so on its own it can never get an
            // account out of .incomplete. This is why the previous attempt changed nothing.
            MXLog.info("GUA-KEYSTORE: blocked by BackupExistsOnServer; checking reachability.")

            // A verified device would have gossiped the secrets to us already, and the state
            // would no longer be .incomplete. So give that a moment to land, and only treat the
            // backup as unreachable once it has not.
            //
            // Deliberately NOT gated on hasDevicesToVerifyAgainst. That only counts whether
            // other device entries exist, and every reinstall leaves one behind: a test account
            // here had five, none of which could supply anything. Gating on it meant the repair
            // declined on essentially every real account, which is exactly how this reached QA
            // three times without fixing anyone.
            if await waitForRecoveryEnabled(timeout: .seconds(15)) {
                MXLog.info("GUA-KEYSTORE: secrets arrived from another device, nothing to repair.")
                return .failure(.failedGeneratingRecoveryKey)
            }

            // Nothing supplied the secrets and no key survives, so nothing can decrypt that
            // backup again. Keeping it preserves only a permanently broken account, so replace
            // it. This does not touch the cross-signing identity, so no contact is warned.
            MXLog.warning("GUA-KEYSTORE: backup unreachable, replacing key storage.")
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

    /// GUA FORK: whether recovery reaches `.enabled` within `timeout`.
    ///
    /// Used to give secret gossip from an already-verified device a chance to land before we
    /// conclude the key backup is unreachable. `settledRecoveryState` is no use here: it returns
    /// the first non-`.unknown` value, which is `.incomplete` immediately.
    private func waitForRecoveryEnabled(timeout: Duration) async -> Bool {
        if recoveryState.value == .enabled {
            return true
        }

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { [recoveryState] in
                for await state in recoveryState.values where state == .enabled {
                    return true
                }
                return false
            }

            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }

            let enabled = await group.next() ?? false
            group.cancelAll()
            return enabled
        }
    }

    /// GUA FORK: everything that can finish encryption setup without destroying anything.
    ///
    /// Split out from the reset so the banner can try this first and stay silent when it works.
    /// Nothing here deletes a key backup or touches the cross-signing identity, so it is safe to
    /// run without asking, and only its failure justifies showing a destructive warning.
    func repairWithoutReset() async -> EncryptionRepairOutcome {
        let state = await settledRecoveryState(timeout: .seconds(2))

        switch state {
        case .enabled:
            return .repaired
        case .unknown, .settingUp:
            // Not a broken account, just a client that cannot see its own state yet. Treating this
            // as "needs a reset" would march the user into a MAS round trip to fix nothing.
            MXLog.warning("GUA-KEYSTORE: state not settled, leaving it alone.")
            return .notYet
        case .disabled, .incomplete:
            // GUA FORK: both broken states take the same path, and it does not wait around.
            //
            // This used to sit for ten seconds hoping a verified device would gossip the secrets
            // across, on top of a ten second settle. That is twenty seconds of a button that looks
            // dead, buying a rescue that never arrives for the accounts this exists to fix: their
            // other device entries are stale reinstalls that answer nothing.
            //
            // It also used to give up here and hand the caller to the reset screen, which is the
            // MAS round trip. It does not have to. Replacing a backup nothing can decrypt any more
            // finishes the job locally, and never touches the cross-signing identity.
            return await provisionKeyStorage()
        }
    }

    /// Provisions key storage, and reports honestly whether it actually worked.
    ///
    /// `enableRecovery` SUCCEEDS on a device that holds no private cross-signing keys: it mints a
    /// new secret store, exports nothing into it, and the account falls straight back to
    /// `.incomplete`. Taking that success at face value made the button look like it did nothing,
    /// so the state itself is the verdict here, not the call's return value.
    ///
    /// There is deliberately no `disableRecovery()` escalation. It cannot help and it can
    /// permanently harm: `Backups.disable()` throws `BackupNotEnabled` exactly when the local store
    /// has no backup version, which is the precise condition under which `enableRecovery` returns
    /// `BackupExistsOnServer`, so the two are exact complements and the escalation can never fire.
    /// In the one case it would fire, it blanks the `m.cross_signing.*` account data, destroying
    /// the last server-side copy of the private cross-signing keys.
    private func provisionKeyStorage() async -> EncryptionRepairOutcome {
        do {
            _ = try await enableRecoveryReturningKey()
        } catch {
            MXLog.warning("GUA-KEYSTORE: could not provision recovery: \(error)")
        }

        // Only the state can say whether that finished the job.
        if await waitForRecoveryEnabled(timeout: .seconds(3)) {
            return .repaired
        }
        MXLog.info("GUA-KEYSTORE: still not enabled, this device needs a reset.")
        return .resetRequired
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
