//
// Copyright 2023, 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation

enum SecureBackupRecoveryState {
    case unknown
    case disabled
    case enabled
    /// Recovery is not set up properly, the user will need to re-enter it so we can cleanup
    /// https://github.com/element-hq/element-meta/issues/2107
    case incomplete
    case settingUp
}

enum SecureBackupKeyBackupState {
    /// Any state where backups couldn't have been enabled but we didn't explicitly disable them on this client.
    /// For all intents and purposes, within the client, this can be treated as `disabled`.
    case unknown
    case enabling
    case enabled
    case disabling
}

/// Represents the progress towards a complete backup before logging out.
enum SecureBackupSteadyState {
    case waiting
    case uploading(uploadedKeyCount: Int, totalKeyCount: Int)
    case error
    case done
}

enum SecureBackupControllerError: Error {
    case failedEnablingBackup
    case failedDisablingBackup
    
    case failedGeneratingRecoveryKey
    case failedConfirmingRecoveryKey
        
    case failedUploadingForBackup
}

// sourcery: AutoMockable
protocol SecureBackupControllerProtocol {
    var recoveryState: CurrentValuePublisher<SecureBackupRecoveryState, Never> { get }
    
    var keyBackupState: CurrentValuePublisher<SecureBackupKeyBackupState, Never> { get }

    /// GUA FORK: true while key storage is being provisioned in the background.
    ///
    /// Provisioning after a reset runs behind the chat list, where the setup banner is still on
    /// screen because the recovery state is genuinely not healthy yet. Without this the banner
    /// reads as an untouched call to action for the whole of that window, so the user presses it,
    /// and the press appears to be what fixed things. It is not; it just arrived after the work.
    var isProvisioningKeyStorage: CurrentValuePublisher<Bool, Never> { get }
    
    func enable() async -> Result<Void, SecureBackupControllerError>
    func disable() async -> Result<Void, SecureBackupControllerError>
    
    func generateRecoveryKey() async -> Result<String, SecureBackupControllerError>
    func confirmRecoveryKey(_ key: String) async -> Result<Void, SecureBackupControllerError>
    /// GUA FORK: pull the secrets this device is missing, using a key we already hold.
    func repairRecovery(with key: String) async -> Result<Void, SecureBackupControllerError>
    /// GUA FORK: repair an `.incomplete` account when no recovery key exists anywhere.
    func provisionRecoveryWithoutKey() async -> Result<String, SecureBackupControllerError>
    /// GUA FORK: everything that can finish encryption setup WITHOUT destroying anything.
    func repairWithoutReset() async -> EncryptionRepairOutcome

    /// GUA FORK: provisions key storage straight after a reset, unconditionally.
    func provisionAfterReset() async -> EncryptionRepairOutcome
    /// GUA FORK: `recoveryState` once it is no longer `.unknown`, so callers never branch on the
    /// initial value. Falls back to `.unknown` if the SDK stays silent past `timeout`.
    func settledRecoveryState(timeout: Duration) async -> SecureBackupRecoveryState
    
    func waitForKeyBackupUpload(uploadStateSubject: CurrentValueSubject<SecureBackupSteadyState, Never>) async -> Result<Void, SecureBackupControllerError>
}

extension SecureBackupControllerProtocol {
    /// GUA FORK: protocol requirements can't carry default arguments, so the common call gets one here.
    func settledRecoveryState() async -> SecureBackupRecoveryState {
        await settledRecoveryState(timeout: .seconds(10))
    }
}

/// GUA FORK: what `repairWithoutReset` managed to do, so callers only offer the destructive reset
/// when one is actually warranted.
enum EncryptionRepairOutcome: Equatable {
    /// Key storage is healthy. Nothing to show the user.
    case repaired
    /// Transient: the client cannot read its own state yet. Change nothing, do not offer a reset.
    case notYet
    /// Everything non-destructive has been tried. Only a reset can finish this device.
    case resetRequired
}
