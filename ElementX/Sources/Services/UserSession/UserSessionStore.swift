//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import Kingfisher
import MatrixRustSDK

class UserSessionStore: UserSessionStoreProtocol {
    private let keychainController: KeychainControllerProtocol
    private let appSettings: AppSettings
    private let networkMonitor: NetworkMonitorProtocol
    private let appHooks: AppHooks
    
    /// Whether or not there are sessions in the store.
    var hasSessions: Bool {
        !keychainController.restorationTokens().isEmpty
    }

    /// All the user IDs managed by the store.
    var userIDs: [String] {
        keychainController.restorationTokens().map(\.userID)
    }
    
    var clientSessionDelegate: ClientSessionDelegate {
        keychainController
    }
    
    init(keychainController: KeychainControllerProtocol,
         appSettings: AppSettings,
         appHooks: AppHooks,
         networkMonitor: NetworkMonitorProtocol) {
        self.keychainController = keychainController
        self.appSettings = appSettings
        self.appHooks = appHooks
        self.networkMonitor = networkMonitor
    }
    
    /// Deletes all data stored in the shared container and keychain
    func reset() {
        MXLog.warning("Resetting the UserSessionStore. All accounts will be affected.")
        try? FileManager.default.removeItem(at: .sessionsBaseDirectory)
        keychainController.removeAllRestorationTokens()
    }
    
    func restoreUserSession() async -> Result<UserSessionProtocol, UserSessionStoreError> {
        let availableCredentials = keychainController.restorationTokens()
        
        guard let credentials = availableCredentials.first else {
            return .failure(.missingCredentials)
        }
        
        switch await restorePreviousLogin(credentials) {
        case .success(let clientProxy):
            restoreKeyStorageIfNeeded(clientProxy)
            return .success(buildUserSessionWithClient(clientProxy))
        case .failure(let error):
            MXLog.error("Failed restoring login with error: \(error)")
            
            // On any restoration failure reset the token and restart
            keychainController.removeRestorationTokenForUsername(credentials.userID)
            credentials.restorationToken.sessionDirectories.delete()
            
            return .failure(error)
        }
    }
    
    func userSession(for client: ClientProtocol, sessionDirectories: SessionDirectories, passphrase: String) async -> Result<UserSessionProtocol, UserSessionStoreError> {
        do {
            let session = try client.session()
            let userID = try client.userId()
            let clientProxy = try await setupProxyForClient(client)
            
            keychainController.setRestorationToken(RestorationToken(session: session,
                                                                    sessionDirectories: sessionDirectories,
                                                                    passphrase: passphrase,
                                                                    pusherNotificationClientIdentifier: clientProxy.pusherNotificationClientIdentifier),
                                                   forUsername: userID)
            
            MXLog.info("Set up session for user \(userID) at: \(sessionDirectories)")

            bootstrapKeyStorageIfNeeded(clientProxy)

            return .success(buildUserSessionWithClient(clientProxy))
        } catch {
            MXLog.error("Failed creating user session with error: \(error)")
            return .failure(.failedSettingUpSession)
        }
    }
    
    func logout(userSession: UserSessionProtocol) {
        let userID = userSession.clientProxy.userID
        let credentials = keychainController.restorationTokens().first { $0.userID == userID }
        keychainController.removeRestorationTokenForUsername(userID)
        // GUA FORK: the stored recovery key belongs to the session being torn down. Left behind
        // it survives logout and gets replayed against whatever secret storage comes next.
        keychainController.removeRecoveryKey(forUsername: userID)
        appSettings.setHasBootstrappedKeyStorage(false, forUserID: userID)
        
        if let credentials {
            credentials.restorationToken.sessionDirectories.delete()
        }
    }
        
    // MARK: - Private

    /// On a brand new login, automatically enables key backup, generates a recovery key and stores
    /// it in the keychain so that re-logins on this device can restore silently.
    ///
    /// Runs fully detached and is completely fail-safe: any error is logged and we fall through to
    /// the existing behaviour. It must never block or fail the login.
    /// Internal rather than private so the provisioning sequence can be asserted in tests.
    func bootstrapKeyStorageIfNeeded(_ clientProxy: ClientProxyProtocol) {
        let secureBackupController = clientProxy.secureBackupController
        let userID = clientProxy.userID

        Task { [weak self] in
            guard let self else { return }

            do {
                guard !appSettings.hasBootstrappedKeyStorage(forUserID: userID) else { return }

                // GUA FORK: everything below can create key storage, so it may not start before the
                // SDK's own provisioning has finished. See `waitForE2EEInitialization`.
                await clientProxy.waitForE2EEInitialization()

                // GUA FORK: wait for the SDK to report where this account actually stands.
                // The subject starts at `.unknown`, and acting on that is what left key
                // storage half-built for every account created so far.
                var state = await secureBackupController.settledRecoveryState()

                // GUA FORK: the published state picks the branch; the flag is persistent, and only
                // the SDK's own answer may set it. Where the two disagree, the account is treated as
                // the SDK reports it. Backup state is deliberately not a condition: `.enabled` is
                // satisfiable with backups marked disabled at the account level, and this latch
                // must not undo that.
                if state == .enabled {
                    let sdkState = secureBackupController.sdkRecoveryState()
                    if sdkState == .enabled {
                        MXLog.info("Recovery already enabled, marking key storage as bootstrapped.")
                        appSettings.setHasBootstrappedKeyStorage(true, forUserID: userID)
                        return
                    }
                    MXLog.warning("Published recovery state is enabled but the SDK reports \(sdkState), continuing with that.")
                    state = sdkState
                }

                // GUA FORK: never act on an unsettled state. Everything below either enables or
                // repairs key storage, and doing that without knowing where the account stands
                // is what broke it in the first place. This runs only on a fresh login; a relaunch
                // takes `restoreKeyStorageIfNeeded`, which does not consult the flag.
                guard state != .unknown else {
                    MXLog.warning("Recovery state unknown, not bootstrapping key storage.")
                    return
                }

                // GUA FORK: storage exists but is missing secrets. If we still hold the key we
                // generated, repair in place instead of rotating, which would orphan the backup.
                if state == .incomplete, let storedKey = keychainController.recoveryKey(forUsername: userID) {
                    MXLog.info("Key storage incomplete, repairing from the stored recovery key.")
                    // GUA FORK: using the key returns without error even when the secrets it was
                    // meant to supply are absent from the store, so only the SDK's recomputed state
                    // can say whether the account is recoverable.
                    if case .success = await secureBackupController.repairRecovery(with: storedKey),
                       secureBackupController.sdkRecoveryState() == .enabled {
                        appSettings.setHasBootstrappedKeyStorage(true, forUserID: userID)
                        return
                    }
                    MXLog.warning("Recovery remains incomplete after using the stored key, falling through to bootstrap.")
                }

                // GUA FORK: a state other than `.disabled` takes the reset-the-key path below, which
                // provisions no backup, so there it still has to be enabled separately.
                if state != .disabled, secureBackupController.keyBackupState.value != .enabled {
                    MXLog.info("Bootstrapping key storage: enabling backup.")
                    if case .failure(let error) = await secureBackupController.enable() {
                        MXLog.error("Failed enabling backup while bootstrapping key storage: \(error)")
                        return
                    }
                }

                MXLog.info("Bootstrapping key storage: generating recovery key.")
                switch await secureBackupController.generateRecoveryKey() {
                case .success(let key):
                    keychainController.setRecoveryKey(key, forUsername: userID)

                    if case .failure(let error) = await secureBackupController.confirmRecoveryKey(key) {
                        MXLog.error("Failed confirming recovery key while bootstrapping key storage: \(error)")
                        return
                    }

                    // GUA FORK: latch only on what the SDK reports after recomputing, plus key
                    // backup reporting enabled. A call that returned without error is not evidence of
                    // either, and the published recovery state can still trail the SDK's answer.
                    // This block never runs again once the flag is set.
                    //
                    // How many backup versions the server holds is deliberately not checked here: the
                    // client API cannot enumerate historical versions. That invariant is held by only
                    // ever invoking one operation capable of creating the initial backup.
                    let finalState = secureBackupController.sdkRecoveryState()
                    guard finalState == .enabled else {
                        MXLog.warning("Key storage did not reach .enabled (\(finalState)); leaving the flag unset.")
                        return
                    }

                    guard secureBackupController.keyBackupState.value == .enabled else {
                        MXLog.warning("Recovery is enabled but key backup is \(secureBackupController.keyBackupState.value); leaving the flag unset.")
                        return
                    }

                    appSettings.setHasBootstrappedKeyStorage(true, forUserID: userID)
                    MXLog.info("Finished bootstrapping key storage.")
                case .failure(let error):
                    MXLog.error("Failed generating recovery key while bootstrapping key storage: \(error)")
                }
            } catch {
                MXLog.error("Unexpected error while bootstrapping key storage: \(error)")
            }
        }
    }

    /// On a re-login on the same device, silently restores from the recovery key stored in the
    /// keychain so the user doesn't hit the encryption confirmation/reset screen.
    ///
    /// Runs fully detached and is completely fail-safe: any error is logged and we fall through to
    /// the existing behaviour.
    func restoreKeyStorageIfNeeded(_ clientProxy: ClientProxyProtocol) {
        let secureBackupController = clientProxy.secureBackupController
        let userID = clientProxy.userID

        Task { [weak self] in
            guard let self else { return }

            do {
                // GUA FORK: everything below can create key storage, so it may not start before the
                // SDK's own provisioning has finished. See `waitForE2EEInitialization`.
                await clientProxy.waitForE2EEInitialization()

                // Only act when recovery isn't already fully enabled (e.g. .incomplete).
                let state = await secureBackupController.settledRecoveryState()
                // Same reasoning as the bootstrap path: an unsettled state is not a signal.
                guard state != .enabled, state != .unknown else { return }

                // GUA FORK: an identity reset leaves recovery `.disabled`, not `.enabled`: it
                // clears the default secret-storage key and does not create a new one. Without
                // this, finishing the repair simply swapped one banner for another, asking the
                // user to "set up recovery" with a recovery key, which is the jargon the whole
                // exercise exists to remove. Provision it for them instead.
                if state == .disabled {
                    MXLog.info("GUA-KEYSTORE: recovery disabled, provisioning it silently.")
                    switch await secureBackupController.generateRecoveryKey() {
                    case .success(let key):
                        // GUA FORK: a successful call is not enough, recovery has to actually reach
                        // `.enabled`. Keep the returned key even when recovery stays incomplete: it
                        // still opens the store that was just created and may be useful for a later
                        // recovery. Anything short of `.enabled` is left to the banner.
                        keychainController.setRecoveryKey(key, forUsername: userID)

                        // The published state cannot answer this: enabling recovery reports `.enabled`
                        // from its own progress listener. Ask the SDK, which recomputes before the call
                        // returns.
                        let finalState = secureBackupController.sdkRecoveryState()
                        guard finalState == .enabled else {
                            MXLog.warning("GUA-KEYSTORE: provisioning left recovery \(finalState), not recording success.")
                            return
                        }

                        MXLog.info("GUA-KEYSTORE: provisioned recovery and stored the key.")
                    case .failure(let error):
                        MXLog.warning("GUA-KEYSTORE: could not provision recovery: \(error)")
                    }
                    return
                }

                // GUA FORK: an account can be `.incomplete` with no stored key at all, so this
                // path has to work without one. Where a key is held, try it first: it is the only
                // route that keeps the existing key backup.
                //
                // A key that does not finish the job is still kept. Neither a thrown error nor a
                // state short of `.enabled` proves it cannot open the store: the SDK reports a
                // wrong key and a network failure through the same case, and using a key that did
                // open the store returns without error whenever the secrets it was meant to supply
                // are simply absent. Retrying a stale key costs two reads and writes nothing, while
                // this keychain is synchronised, so discarding takes the credential off the
                // account's other devices too.
                if let storedKey = keychainController.recoveryKey(forUsername: userID) {
                    MXLog.info("GUA-KEYSTORE: state=\(state), stored key present, trying it.")
                    let result = state == .incomplete
                        ? await secureBackupController.repairRecovery(with: storedKey)
                        : await secureBackupController.confirmRecoveryKey(storedKey)

                    // GUA FORK: as above, the call returning is not the signal and the published
                    // state can still be the pre-operation one. Ask the SDK.
                    if case .success = result,
                       secureBackupController.sdkRecoveryState() == .enabled {
                        MXLog.info("GUA-KEYSTORE: repaired using the stored key.")
                        return
                    }

                    MXLog.warning("GUA-KEYSTORE: recovery remains incomplete after using the stored key, keeping it and falling through.")
                }

                guard await secureBackupController.settledRecoveryState() == .incomplete else { return }

                // GUA FORK: this used to call provisionRecoveryWithoutKey, which enables recovery
                // and writes the fresh key back to the keychain. That was a self-perpetuating
                // rotation: enabling mints a new secret store, the account stays .incomplete
                // because there are no private cross-signing keys to export into it, and next
                // launch the key we just saved opens a store containing nothing, so it discards it
                // and rotates again. Worse across platforms, since the same account on Android was
                // doing the same thing at its own launch and invalidating whatever this saved.
                //
                // repairWithoutReset only enables recovery where that can actually finish the job,
                // and reports honestly otherwise. Nothing here is destructive, and .resetRequired
                // is left to the banner, where the user is present to consent.
                switch await secureBackupController.repairWithoutReset() {
                case .repaired:
                    MXLog.info("GUA-KEYSTORE: key storage repaired at launch.")
                case .notYet:
                    MXLog.info("GUA-KEYSTORE: state not readable yet, will retry next launch.")
                case .resetRequired:
                    MXLog.warning("GUA-KEYSTORE: only a reset can finish this device; leaving it to the banner.")
                case .identityIncompleteAfterReset:
                    MXLog.warning("GUA-KEYSTORE: the account is incomplete after a reset; leaving it to the banner.")
                }
            } catch {
                MXLog.error("Unexpected error while restoring key storage: \(error)")
            }
        }
    }

    private func buildUserSessionWithClient(_ clientProxy: ClientProxyProtocol) -> UserSessionProtocol {
        let mediaProvider = MediaProvider(mediaLoader: clientProxy.mediaLoader,
                                          imageCache: .onlyInMemory,
                                          homeserverReachabilityPublisher: clientProxy.homeserverReachabilityPublisher)
        
        let voiceMessageMediaManager = VoiceMessageMediaManager(mediaProvider: mediaProvider)
        
        return UserSession(clientProxy: clientProxy,
                           mediaProvider: mediaProvider,
                           voiceMessageMediaManager: voiceMessageMediaManager)
    }
    
    private func restorePreviousLogin(_ credentials: KeychainCredentials) async -> Result<ClientProxyProtocol, UserSessionStoreError> {
        guard credentials.restorationToken.sessionDirectories.isNonTransientUserDataValid() else {
            MXLog.error("Failed restoring login, missing non-transient user data")
            return .failure(.failedRestoringLogin)
        }
        
        let homeserverURL = credentials.restorationToken.session.homeserverUrl
        appHooks.remoteSettingsHook.loadCache(forHomeserver: homeserverURL, applyingTo: appSettings)
        
        let builder = ClientBuilder
            .baseBuilder(httpProxy: URL(string: homeserverURL)?.globalProxy,
                         slidingSync: .restored,
                         sessionDelegate: keychainController,
                         appHooks: appHooks,
                         enableOnlySignedDeviceIsolationMode: appSettings.enableOnlySignedDeviceIsolationMode,
                         enableKeyShareOnInvite: appSettings.enableKeyShareOnInvite,
                         threadsEnabled: appSettings.threadsEnabled)
            .sqliteStore(config: .init(dataPath: credentials.restorationToken.sessionDirectories.dataPath,
                                       cachePath: credentials.restorationToken.sessionDirectories.cachePath)
                    .passphrase(passphrase: credentials.restorationToken.passphrase))
            .username(username: credentials.userID)
            .homeserverUrl(url: homeserverURL)
        
        do {
            let client = try await builder.build()
            try await client.restoreSession(session: credentials.restorationToken.session)
            
            MXLog.info("Set up session for user \(credentials.userID) at: \(credentials.restorationToken.sessionDirectories)")
            
            Task(priority: .low) { await appHooks.remoteSettingsHook.updateCache(using: client) }
            
            return try await .success(setupProxyForClient(client))
        } catch UserSessionStoreError.failedSettingUpClientProxy(let error) {
            // If this has failed, there is likely something wrong with the creation of the sync service
            // There is nothing we can do, but at the same time we don't want the user to the get logged out
            // So it's better to crash here and let the app restart
            fatalError("Failed setting up the client proxy with error: \(error)")
        } catch {
            MXLog.error("Failed restoring login with error: \(error)")
            return .failure(.failedRestoringLogin)
        }
    }
    
    private func setupProxyForClient(_ client: ClientProtocol) async throws -> ClientProxyProtocol {
        do {
            // GUA FORK: a recovery key minted by the secure backup controller replaces this
            // account's stored one at once. The keychain itself stays here.
            let userID = try client.userId()
            return try await ClientProxy(client: client,
                                         networkMonitor: networkMonitor,
                                         appSettings: appSettings,
                                         persistRecoveryKey: { [keychainController] key in
                                             keychainController.setRecoveryKey(key, forUsername: userID)
                                         },
                                         storedRecoveryKey: { [keychainController] in
                                             keychainController.recoveryKey(forUsername: userID)
                                         })
        } catch {
            throw UserSessionStoreError.failedSettingUpClientProxy(error)
        }
    }
}
