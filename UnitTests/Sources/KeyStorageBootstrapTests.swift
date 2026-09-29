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

/// Key-storage bootstrap and post-reset provisioning.
///
/// A fresh account must end up with exactly one key backup. Only one operation may create it, because a
/// second version is never cleaned up: a later identity reset deletes only the current version, and the
/// survivor makes every subsequent `Recovery::enable` fail with `backupExistsOnServer` for the life of the
/// account.
class KeyStorageBootstrapTests: XCTestCase {
    private var secureBackup: SecureBackupControllerMock!
    private var clientProxy: ClientProxyMock!
    private var keychain: KeychainControllerMock!
    private var appSettings: AppSettings!
    private var store: UserSessionStore!

    private static let userID = "@fresh:dev.gua.sarahlacerda.me"

    override func setUp() {
        AppSettings.resetAllSettings()
        appSettings = AppSettings()
        keychain = KeychainControllerMock()
        secureBackup = SecureBackupControllerMock()
        clientProxy = ClientProxyMock(.init(userID: Self.userID))
        clientProxy.underlyingSecureBackupController = secureBackup
        store = UserSessionStore(keychainController: keychain,
                                 appSettings: appSettings,
                                 appHooks: AppHooks(),
                                 networkMonitor: NetworkMonitorMock.default)
    }

    override func tearDown() {
        AppSettings.resetAllSettings()
    }

    // MARK: - a fresh account has one provisioning owner

    /// A fresh account is `.disabled`, and enabling recovery creates the key backup itself, so nothing
    /// else may create one.
    func testAFreshAccountEnablesRecoveryAndNothingElseCreatesABackup() async {
        givenAFreshAccount()

        await whenBootstrapping()

        XCTAssertEqual(secureBackup.generateRecoveryKeyCallsCount, 1)
        XCTAssertEqual(secureBackup.enableCallsCount, 0,
                       "enabling backup separately is what created a second version")
    }

    /// The local backup state lags the version just created on the server, so it is not a safe basis for
    /// deciding whether to create one. On a fresh account it is not consulted at all.
    func testAFreshAccountIgnoresALaggingLocalBackupState() async {
        givenAFreshAccount()
        // The server already has the version enabling recovery is about to create, while the client still
        // reports backup as not enabled (`unknown`).
        secureBackup.underlyingKeyBackupState = CurrentValuePublisher<SecureBackupKeyBackupState, Never>(SecureBackupKeyBackupState.unknown)

        await whenBootstrapping()

        XCTAssertEqual(secureBackup.enableCallsCount, 0)
        XCTAssertEqual(secureBackup.generateRecoveryKeyCallsCount, 1)
    }

    func testAFreshAccountStoresItsRecoveryKey() async {
        givenAFreshAccount()

        await whenBootstrapping()

        XCTAssertEqual(keychain.setRecoveryKeyForUsernameReceivedArguments?.key, "a-recovery-key")
        XCTAssertEqual(keychain.setRecoveryKeyForUsernameReceivedArguments?.username, Self.userID)
    }

    func testAFreshAccountIsOnlyLatchedOnceRecoveryAndBackupBothReportEnabled() async {
        givenAFreshAccount()
        givenRecoveryBecomesEnabledAfterProvisioning()
        // Enabling recovery is what creates the backup, so the backup state only reaches enabled here.
        secureBackup.generateRecoveryKeyClosure = { [weak secureBackup] in
            secureBackup?.underlyingKeyBackupState = CurrentValuePublisher<SecureBackupKeyBackupState, Never>(SecureBackupKeyBackupState.enabled)
            return .success("a-recovery-key")
        }

        await whenBootstrapping()

        XCTAssertTrue(appSettings.hasBootstrappedKeyStorage(forUserID: Self.userID))
    }

    /// The SDK provisions the key backup itself in a background task. Enabling recovery before that task
    /// finishes creates a second version, because `Recovery::enable` only skips creating one when a backup
    /// is already enabled locally.
    func testTheSDKsInitialisationIsJoinedBeforeAnythingCanCreateAKeyBackup() async {
        givenAFreshAccount()
        var order: [String] = []
        clientProxy.waitForE2EEInitializationClosure = { order.append("join") }
        secureBackup.settledRecoveryStateTimeoutClosure = { _ in
            order.append("read-state")
            return .disabled
        }
        secureBackup.generateRecoveryKeyClosure = {
            order.append("generate")
            return .success("a-recovery-key")
        }

        await whenBootstrapping()

        // The state is read once more at the end, as the postcondition, so only the prefix is pinned.
        XCTAssertEqual(Array(order.prefix(3)), ["join", "read-state", "generate"],
                       "the join has to come first, including before the state that decides the branch")
    }

    /// The join is unconditional. It is not a fresh-account optimisation: every branch below it can
    /// reach `Recovery::enable`.
    func testTheSDKsInitialisationIsJoinedOnEveryBranch() async {
        givenAFreshAccount()
        secureBackup.settledRecoveryStateTimeoutReturnValue = .incomplete
        keychain.recoveryKeyForUsernameReturnValue = nil

        await whenBootstrapping()

        XCTAssertEqual(clientProxy.waitForE2EEInitializationCallsCount, 1)
    }

    /// Nothing is joined once the account is already latched, because that path does no provisioning.
    func testAnAlreadyBootstrappedAccountDoesNoWork() async {
        givenAFreshAccount()
        appSettings.setHasBootstrappedKeyStorage(true, forUserID: Self.userID)

        await whenBootstrapping()

        XCTAssertEqual(clientProxy.waitForE2EEInitializationCallsCount, 0)
        XCTAssertEqual(secureBackup.generateRecoveryKeyCallsCount, 0)
    }

    /// Recovery reporting enabled is not on its own evidence that key storage is finished.
    func testRecoveryEnabledButBackupNotEnabledIsNotLatched() async {
        givenAFreshAccount()
        givenRecoveryBecomesEnabledAfterProvisioning()
        // Backup never reaches enabled. `givenAFreshAccount` already leaves it at `unknown`.

        await whenBootstrapping()

        XCTAssertFalse(appSettings.hasBootstrappedKeyStorage(forUserID: Self.userID),
                       "an unfinished bootstrap must be retried on the next launch, not latched")
    }

    /// An account that is not fresh takes the reset-the-key path, which provisions no backup, so there
    /// backup still has to be enabled separately.
    func testANonFreshAccountStillEnablesBackupSeparately() async {
        givenAFreshAccount()
        secureBackup.settledRecoveryStateTimeoutReturnValue = .incomplete
        secureBackup.underlyingKeyBackupState = CurrentValuePublisher<SecureBackupKeyBackupState, Never>(SecureBackupKeyBackupState.unknown)
        // No stored recovery key, so the in-place repair is skipped and it falls through to bootstrap.
        keychain.recoveryKeyForUsernameReturnValue = nil

        await whenBootstrapping()

        XCTAssertEqual(secureBackup.enableCallsCount, 1)
    }

    // MARK: - only the SDK's recomputed state can close out an operation

    /// Using the stored key returns without error even when the secrets it was meant to supply are
    /// absent from the store, so the call alone must not latch the account as bootstrapped.
    func testAStoredKeyRepairThatLeavesRecoveryIncompleteDoesNotLatch() async {
        givenAFreshAccount()
        secureBackup.settledRecoveryStateTimeoutReturnValue = .incomplete
        secureBackup.repairRecoveryWithReturnValue = .success(())
        secureBackup.sdkRecoveryStateReturnValue = .incomplete
        keychain.recoveryKeyForUsernameReturnValue = "a-stored-key"

        await whenBootstrapping()

        XCTAssertFalse(appSettings.hasBootstrappedKeyStorage(forUserID: Self.userID),
                       "a repair that leaves recovery incomplete is not a completed bootstrap")
    }

    /// The physical-device case. Enabling recovery publishes `.enabled` about itself and genuinely
    /// enables the backup, so neither of those can close out the bootstrap on a device that cannot
    /// complete secret storage.
    func testTheBootstrapLatchIgnoresTheStateEnablingPublishedAboutItself() async {
        givenAFreshAccount()
        givenRecoveryBecomesEnabledAfterProvisioning() // what enabling recovery published
        secureBackup.underlyingKeyBackupState = CurrentValuePublisher<SecureBackupKeyBackupState, Never>(SecureBackupKeyBackupState.enabled)
        secureBackup.sdkRecoveryStateReturnValue = .incomplete // what the account is actually in

        await whenBootstrapping()

        XCTAssertFalse(appSettings.hasBootstrappedKeyStorage(forUserID: Self.userID),
                       "the backup being enabled says nothing about the cross-signing secrets")
    }

    /// The published state can still be the pre-operation one, so a repair that did reach `.enabled`
    /// must be accepted rather than treated as a failure.
    func testAStoredKeyRepairThatReachedEnabledIsAcceptedWhenThePublishedStateLags() async {
        givenAFreshAccount()
        secureBackup.settledRecoveryStateTimeoutReturnValue = .incomplete // stale publication
        secureBackup.repairRecoveryWithReturnValue = .success(())
        secureBackup.sdkRecoveryStateReturnValue = .enabled
        keychain.recoveryKeyForUsernameReturnValue = "a-stored-key"

        await whenRestoring()

        XCTAssertEqual(keychain.removeRecoveryKeyForUsernameCallsCount, 0,
                       "a key that just restored the account must not be discarded")
        XCTAssertEqual(secureBackup.repairWithoutResetCallsCount, 0)
    }

    // MARK: - the restore path only records a provisioning that finished

    /// A device holding the private cross-signing keys reaches `.enabled`, which is the success
    /// condition for this flow.
    func testRestoringADisabledAccountThatReachesEnabledKeepsTheKey() async {
        givenAFreshAccount()
        secureBackup.sdkRecoveryStateReturnValue = .enabled

        await whenRestoring()

        XCTAssertEqual(secureBackup.generateRecoveryKeyCallsCount, 1)
        XCTAssertEqual(keychain.setRecoveryKeyForUsernameReceivedArguments?.key, "a-recovery-key")
    }

    /// A device without the private cross-signing keys cannot finish, and the call still returns
    /// successfully. The key is kept because it opens the store that was just created, and nothing
    /// destructive runs.
    func testRestoringADisabledAccountThatStaysIncompleteStillKeepsTheKey() async {
        givenAFreshAccount()
        secureBackup.sdkRecoveryStateReturnValue = .incomplete

        await whenRestoring()

        XCTAssertEqual(keychain.setRecoveryKeyForUsernameReceivedArguments?.key, "a-recovery-key",
                       "the key is the only credential for the store that was just created")
        XCTAssertEqual(keychain.removeRecoveryKeyForUsernameCallsCount, 0)
        XCTAssertEqual(secureBackup.disableCallsCount, 0)
        XCTAssertEqual(secureBackup.provisionRecoveryWithoutKeyCallsCount, 0)
    }

    /// The regression this branch exists for. Enabling recovery publishes `.enabled` from its own
    /// progress listener, so the published state agrees with the call that just made it. Only the
    /// SDK recomputes, so only the SDK can say whether provisioning finished.
    func testTheOutcomeIsJudgedBySDKStateNotTheStateTheClientPublished() async {
        givenAFreshAccount()
        // What enabling recovery optimistically published about itself.
        secureBackup.settledRecoveryStateTimeoutClosure = { [weak secureBackup] _ in
            secureBackup?.settledRecoveryStateTimeoutCallsCount == 1 ? .disabled : .enabled
        }
        // What the account is actually in.
        secureBackup.sdkRecoveryStateReturnValue = .incomplete

        await whenRestoring()

        XCTAssertEqual(secureBackup.sdkRecoveryStateCallsCount, 1,
                       "the outcome must be read from the SDK, not from the published state")
    }

    /// The restore path provisions, it never latches: the bootstrap flag belongs to the login path.
    func testTheRestorePathNeverLatchesTheBootstrapFlag() async {
        givenAFreshAccount()
        secureBackup.sdkRecoveryStateReturnValue = .enabled

        await whenRestoring()

        XCTAssertFalse(appSettings.hasBootstrappedKeyStorage(forUserID: Self.userID))
    }

    // MARK: - post-reset provisioning

    /// `backupExistsOnServer` is a structural refusal, not a state that settles, so spending the backoff
    /// on it only delays the answer. The loop is also given no way to delete anything: the existing
    /// backup may hold the only copy of the account's room keys.
    func testABackupAlreadyOnTheServerFailsAtOnceInsteadOfWaitingOutTheBackoff() async {
        var enableCalls = 0
        var waits: [Duration] = []

        let start = ContinuousClock.now
        let outcome = await SecureBackupController.provisionLoop(backoff: [.seconds(3), .seconds(5), .seconds(10), .seconds(20), .seconds(20)],
                                                                 isEnabled: { false },
                                                                 enableRecovery: {
                                                                     enableCalls += 1
                                                                     throw RecoveryError.BackupExistsOnServer
                                                                 },
                                                                 waitForEnabled: { timeout in
                                                                     waits.append(timeout)
                                                                     return false
                                                                 })
        let elapsed = start.duration(to: .now)

        XCTAssertEqual(outcome, .resetRequired)
        XCTAssertEqual(enableCalls, 1, "a structural refusal must not be retried")
        XCTAssertTrue(waits.isEmpty, "the backoff must not be spent on a refusal that cannot change")
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    /// A transient error is not structural, so the backoff is still spent on it.
    func testATransientErrorStillRetries() async {
        var enableCalls = 0

        let outcome = await SecureBackupController.provisionLoop(backoff: [.milliseconds(1), .milliseconds(1)],
                                                                 isEnabled: { false },
                                                                 enableRecovery: {
                                                                     enableCalls += 1
                                                                     throw SecureBackupControllerError.failedEnablingBackup
                                                                 },
                                                                 waitForEnabled: { _ in false })

        XCTAssertEqual(outcome, .resetRequired)
        XCTAssertEqual(enableCalls, 2, "a transient failure is retried across the backoff")
    }

    /// A correctly bootstrapped account can provision again after a reset, because no orphan blocks it.
    func testProvisioningSucceedsWhenNoBackupBlocksIt() async {
        var enabled = false

        let outcome = await SecureBackupController.provisionLoop(backoff: [.milliseconds(1), .milliseconds(1)],
                                                                 isEnabled: { enabled },
                                                                 enableRecovery: { enabled = true },
                                                                 waitForEnabled: { _ in enabled })

        XCTAssertEqual(outcome, .repaired)
    }

    func testProvisioningReturnsRepairedWithoutActingWhenAlreadyEnabled() async {
        var enableCalls = 0

        let outcome = await SecureBackupController.provisionLoop(backoff: [.milliseconds(1)],
                                                                 isEnabled: { true },
                                                                 enableRecovery: { enableCalls += 1 },
                                                                 waitForEnabled: { _ in true })

        XCTAssertEqual(outcome, .repaired)
        XCTAssertEqual(enableCalls, 0, "rotating over a store that already works would undo it")
    }

    // MARK: - helpers

    private func givenAFreshAccount() {
        secureBackup.settledRecoveryStateTimeoutReturnValue = .disabled
        secureBackup.underlyingKeyBackupState = CurrentValuePublisher<SecureBackupKeyBackupState, Never>(SecureBackupKeyBackupState.unknown)
        secureBackup.generateRecoveryKeyReturnValue = .success("a-recovery-key")
        secureBackup.confirmRecoveryKeyReturnValue = .success(())
        secureBackup.enableReturnValue = .success(())
        // A healthy account: the SDK agrees that recovery finished. Tests that model a device which
        // cannot complete secret storage override this.
        secureBackup.sdkRecoveryStateReturnValue = .enabled
        secureBackup.repairRecoveryWithReturnValue = .success(())
        secureBackup.repairWithoutResetReturnValue = .notYet
        keychain.recoveryKeyForUsernameReturnValue = nil
    }

    /// A real fresh account reports `.disabled` on the way in and `.enabled` once recovery is provisioned,
    /// so the entry read and the postcondition read cannot return the same value.
    private func givenRecoveryBecomesEnabledAfterProvisioning() {
        secureBackup.settledRecoveryStateTimeoutClosure = { [weak secureBackup] _ in
            secureBackup?.settledRecoveryStateTimeoutCallsCount == 1 ? .disabled : .enabled
        }
    }

    private func whenRestoring() async {
        store.restoreKeyStorageIfNeeded(clientProxy)
        // The restore runs detached, so give it a moment to finish.
        try? await Task.sleep(for: .milliseconds(400))
    }

    private func whenBootstrapping() async {
        store.bootstrapKeyStorageIfNeeded(clientProxy)
        // The bootstrap runs detached, so give it a moment to finish.
        try? await Task.sleep(for: .milliseconds(400))
    }
}
