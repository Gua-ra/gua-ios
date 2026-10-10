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

    /// The home screen can appear as soon as the session is handed out, so the flag that holds back the
    /// setup banner has to be up before the bootstrap returns, and down once it ends.
    func testTheBootstrapIsAnnouncedBeforeItReturnsAndUntilItEnds() async {
        givenAFreshAccount()

        store.bootstrapKeyStorageIfNeeded(clientProxy)
        XCTAssertEqual(secureBackup.setBootstrappingKeyStorageReceivedIsBootstrapping, true)

        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(secureBackup.setBootstrappingKeyStorageCallsCount, 2)
        XCTAssertEqual(secureBackup.setBootstrappingKeyStorageReceivedIsBootstrapping, false)
    }

    func testAnAlreadyBootstrappedAccountAnnouncesNothing() async {
        givenAFreshAccount()
        appSettings.setHasBootstrappedKeyStorage(true, forUserID: Self.userID)

        await whenBootstrapping()

        XCTAssertEqual(secureBackup.setBootstrappingKeyStorageCallsCount, 0)
    }

    /// Recovery reporting enabled is not on its own evidence that key storage is finished.
    func testRecoveryEnabledButBackupNotEnabledIsNotLatched() async {
        givenAFreshAccount()
        givenRecoveryBecomesEnabledAfterProvisioning()
        // Backup never reaches enabled. `givenAFreshAccount` already leaves it at `unknown`.

        await whenBootstrapping()

        XCTAssertFalse(appSettings.hasBootstrappedKeyStorage(forUserID: Self.userID),
                       "an unfinished bootstrap must not be latched")
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

    // MARK: - the early latch trusts only the SDK

    /// The published state may pick the branch, but the flag is persistent: only the SDK's own answer
    /// may set it. A disagreement is not a finished account, so the bootstrap goes on.
    func testAPublishedEnabledWithAnIncompleteSDKStateDoesNotLatchAndContinues() async {
        givenAFreshAccount()
        secureBackup.settledRecoveryStateTimeoutReturnValue = .enabled
        givenTheSDKReports(.incomplete)

        await whenBootstrapping()

        XCTAssertFalse(appSettings.hasBootstrappedKeyStorage(forUserID: Self.userID))
        XCTAssertEqual(secureBackup.generateRecoveryKeyCallsCount, 1,
                       "the account is treated as the SDK reports it, not left untreated")
    }

    /// An account the SDK confirms as `.enabled` needs nothing from the bootstrap.
    func testAPublishedEnabledConfirmedByTheSDKLatchesWithoutProvisioning() async {
        givenAFreshAccount()
        secureBackup.settledRecoveryStateTimeoutReturnValue = .enabled
        givenTheSDKReports(.enabled)

        await whenBootstrapping()

        XCTAssertTrue(appSettings.hasBootstrappedKeyStorage(forUserID: Self.userID))
        XCTAssertEqual(secureBackup.generateRecoveryKeyCallsCount, 0)
        XCTAssertEqual(secureBackup.enableCallsCount, 0)
        XCTAssertEqual(secureBackup.repairRecoveryWithCallsCount, 0)
    }

    /// `.enabled` is satisfiable with backups marked disabled at the account level. The early latch
    /// neither requires backup to report enabled nor re-enables it.
    func testTheEarlyLatchDoesNotRequireOrReenableKeyBackup() async {
        givenAFreshAccount()
        secureBackup.settledRecoveryStateTimeoutReturnValue = .enabled
        givenTheSDKReports(.enabled)
        secureBackup.underlyingKeyBackupState = CurrentValuePublisher<SecureBackupKeyBackupState, Never>(SecureBackupKeyBackupState.unknown)

        await whenBootstrapping()

        XCTAssertTrue(appSettings.hasBootstrappedKeyStorage(forUserID: Self.userID))
        XCTAssertEqual(secureBackup.enableCallsCount, 0,
                       "an account-level choice is not reversed to satisfy the latch")
    }

    /// On a fresh account the SDK is consulted only as the postcondition, after provisioning, so the
    /// early latch is never what makes the fresh-account tests pass.
    func testAFreshAccountProvisionsBeforeTheSDKStateIsConsulted() async {
        givenAFreshAccount()
        var order: [String] = []
        secureBackup.sdkRecoveryStateClosure = {
            order.append("sdk-read")
            return .enabled
        }
        secureBackup.generateRecoveryKeyClosure = {
            order.append("generate")
            return .success("a-recovery-key")
        }

        await whenBootstrapping()

        XCTAssertEqual(order, ["generate", "sdk-read"])
    }

    // MARK: - a stored recovery key is only discarded when it is proven useless

    /// A thrown error does not prove the key cannot open the store: the SDK reports a wrong key and
    /// a network failure through the same case.
    func testAFailedStoredKeyRecoveryKeepsTheKey() async {
        givenAFreshAccount()
        secureBackup.settledRecoveryStateTimeoutReturnValue = .incomplete
        secureBackup.repairRecoveryWithReturnValue = .failure(.failedConfirmingRecoveryKey)
        givenTheSDKReports(.incomplete)
        keychain.recoveryKeyForUsernameReturnValue = "a-stored-key"

        await whenRestoring()

        XCTAssertEqual(keychain.removeRecoveryKeyForUsernameCallsCount, 0)
        XCTAssertEqual(secureBackup.repairWithoutResetCallsCount, 1, "the existing fallback still runs")
    }

    /// Using a key that did open the store returns without error whenever the secrets it was meant
    /// to supply are absent, so an incomplete outcome says nothing about the key.
    func testAStoredKeyRecoveryThatRemainsIncompleteKeepsTheKey() async {
        givenAFreshAccount()
        secureBackup.settledRecoveryStateTimeoutReturnValue = .incomplete
        secureBackup.repairRecoveryWithReturnValue = .success(())
        givenTheSDKReports(.incomplete)
        keychain.recoveryKeyForUsernameReturnValue = "a-stored-key"

        await whenRestoring()

        XCTAssertEqual(keychain.removeRecoveryKeyForUsernameCallsCount, 0)
        XCTAssertEqual(secureBackup.repairWithoutResetCallsCount, 1, "the existing fallback still runs")
    }

    /// Nothing on this path may destroy anything: no backup deleted, no recovery disabled, no
    /// storage rotated.
    func testTheStoredKeyPathCallsNoDestructiveAPI() async {
        givenAFreshAccount()
        secureBackup.settledRecoveryStateTimeoutReturnValue = .incomplete
        secureBackup.repairRecoveryWithReturnValue = .failure(.failedConfirmingRecoveryKey)
        givenTheSDKReports(.incomplete)
        keychain.recoveryKeyForUsernameReturnValue = "a-stored-key"

        await whenRestoring()

        XCTAssertEqual(secureBackup.disableCallsCount, 0)
        XCTAssertEqual(secureBackup.provisionRecoveryWithoutKeyCallsCount, 0)
        XCTAssertEqual(secureBackup.generateRecoveryKeyCallsCount, 0)
    }

    // MARK: - only the SDK's recomputed state can close out an operation

    /// Using the stored key returns without error even when the secrets it was meant to supply are
    /// absent from the store, so the call alone must not latch the account as bootstrapped.
    func testAStoredKeyRepairThatLeavesRecoveryIncompleteDoesNotLatch() async {
        givenAFreshAccount()
        secureBackup.settledRecoveryStateTimeoutReturnValue = .incomplete
        secureBackup.repairRecoveryWithReturnValue = .success(())
        givenTheSDKReports(.incomplete)
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
        givenTheSDKReports(.incomplete) // what the account is actually in

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
        givenTheSDKReports(.enabled)
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
        givenTheSDKReports(.enabled)

        await whenRestoring()

        XCTAssertEqual(secureBackup.generateRecoveryKeyCallsCount, 1)
        XCTAssertEqual(keychain.setRecoveryKeyForUsernameReceivedArguments?.key, "a-recovery-key")
    }

    /// A device without the private cross-signing keys cannot finish, and the call still returns
    /// successfully. The key is kept because it opens the store that was just created, and nothing
    /// destructive runs.
    func testRestoringADisabledAccountThatStaysIncompleteStillKeepsTheKey() async {
        givenAFreshAccount()
        givenTheSDKReports(.incomplete)

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
        givenTheSDKReports(.incomplete)

        await whenRestoring()

        XCTAssertEqual(secureBackup.sdkRecoveryStateCallsCount, 1,
                       "the outcome must be read from the SDK, not from the published state")
    }

    /// The restore path provisions, it never latches: the bootstrap flag belongs to the login path.
    func testTheRestorePathNeverLatchesTheBootstrapFlag() async {
        givenAFreshAccount()
        givenTheSDKReports(.enabled)

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
                                                                 authoritativeState: { .disabled },
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
                                                                 authoritativeState: { .disabled },
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
                                                                 authoritativeState: { enabled ? .enabled : .disabled },
                                                                 waitForEnabled: { _ in enabled })

        XCTAssertEqual(outcome, .repaired)
    }

    func testProvisioningReturnsRepairedWithoutActingWhenAlreadyEnabled() async {
        var enableCalls = 0

        let outcome = await SecureBackupController.provisionLoop(backoff: [.milliseconds(1)],
                                                                 isEnabled: { true },
                                                                 enableRecovery: { enableCalls += 1 },
                                                                 authoritativeState: { .enabled },
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
        // The SDK's own answer follows the account: `.disabled` until recovery has been provisioned
        // or repaired, `.enabled` afterwards. It is a closure, so a plain `sdkRecoveryStateReturnValue`
        // assignment is ignored; pin a fixed answer with `givenTheSDKReports`.
        secureBackup.sdkRecoveryStateClosure = { [weak secureBackup] in
            guard let secureBackup else { return .unknown }
            let provisioned = secureBackup.generateRecoveryKeyCallsCount > 0
                || secureBackup.repairRecoveryWithCallsCount > 0
            return provisioned ? .enabled : .disabled
        }
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

    /// Pins the SDK's own answer, overriding the fixture's transition.
    private func givenTheSDKReports(_ state: SecureBackupRecoveryState) {
        secureBackup.sdkRecoveryStateClosure = { state }
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
