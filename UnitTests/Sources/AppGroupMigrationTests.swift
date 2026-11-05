//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import MatrixRustSDK
import Testing

final class AppGroupMigrationTests {
    private let userID = "@alice:example.com"
    
    private var root: URL!
    private var directories: AppGroupMigration.Directories!
    private var suiteName: String!
    private var keychainController: KeychainControllerMock!
    private var storedTokens: [String: RestorationToken] = [:]
    private var logEntries: [AppGroupMigration.LogEntry] = []
    
    private var migration: AppGroupMigration {
        AppGroupMigration(directories: directories, suiteName: suiteName, keychainController: keychainController) { [unowned self] in
            logEntries.append($0)
        }
    }
    
    private var suite: UserDefaults {
        UserDefaults(suiteName: suiteName)! // swiftlint:disable:this force_unwrapping
    }
    
    init() {
        root = FileManager.default.temporaryDirectory.appending(component: "AppGroupMigrationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let legacy = root.appending(component: "Legacy", directoryHint: .isDirectory)
        let group = root.appending(component: "Group", directoryHint: .isDirectory)
        directories = .init(legacyPreferences: legacy.appending(path: "Library/Preferences/group.test.plist"),
                            legacySessions: legacy.appending(path: "Library/Application Support/test/Sessions", directoryHint: .isDirectory),
                            legacySessionCaches: legacy.appending(path: "Library/Caches/test/Sessions", directoryHint: .isDirectory),
                            sessions: group.appending(path: "Library/Application Support/test/Sessions", directoryHint: .isDirectory),
                            sessionCaches: group.appending(path: "Library/Caches/test/Sessions", directoryHint: .isDirectory))
        suiteName = "AppGroupMigrationTests.\(UUID().uuidString)"
        
        storedTokens = [:]
        logEntries = []
        keychainController = KeychainControllerMock()
        keychainController.restorationTokensClosure = { [unowned self] in
            storedTokens.map { KeychainCredentials(userID: $0.key, restorationToken: $0.value) }
        }
        keychainController.setRestorationTokenForUsernameClosure = { [unowned self] token, userID in
            storedTokens[userID] = token
        }
    }
    
    isolated deinit {
        suite.removePersistentDomain(forName: suiteName)
        try? setLegacyPreferencesRemovable(true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: directories.legacyPreferences.path(percentEncoded: false))
        try? FileManager.default.removeItem(at: root)
    }
    
    // MARK: - Settings
    
    @Test
    func legacySettingsFillAnEmptyGroupSuite() throws {
        try writeLegacyPreferences(["lastVersionLaunched": "25.09.12", "enableNotifications": false])
        
        #expect(migration.run() == .migrated)
        
        #expect(suite.string(forKey: "lastVersionLaunched") == "25.09.12")
        #expect(suite.object(forKey: "enableNotifications") as? Bool == false)
        #expect(!FileManager.default.fileExists(atPath: directories.legacyPreferences.path(percentEncoded: false)))
    }
    
    @Test
    func legacySettingsReplaceAStaleGroupSuite() throws {
        suite.set("25.08.1", forKey: "lastVersionLaunched")
        suite.set(true, forKey: "hasBootstrappedKeyStorage.@alice:example.com")
        try writeLegacyPreferences(["lastVersionLaunched": "25.09.12", "seenInvites": Data([1, 2, 3])])
        
        #expect(migration.run() == .migrated)
        
        #expect(suite.string(forKey: "lastVersionLaunched") == "25.09.12")
        #expect(suite.data(forKey: "seenInvites") == Data([1, 2, 3]))
        #expect(suite.object(forKey: "hasBootstrappedKeyStorage.@alice:example.com") == nil)
    }
    
    @Test
    func unreadableLegacySettingsDeferWithoutTouchingAnything() throws {
        suite.set("25.08.1", forKey: "lastVersionLaunched")
        try writeLegacyPreferences(["lastVersionLaunched": "25.09.12"])
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: directories.legacyPreferences.path(percentEncoded: false))
        let legacyData = try makeStore(in: directories.legacySessions)
        storedTokens[userID] = makeToken(dataDirectory: legacyData)
        
        #expect(migration.run() == .deferred)
        
        #expect(suite.string(forKey: "lastVersionLaunched") == "25.08.1")
        #expect(FileManager.default.fileExists(atPath: directories.legacyPreferences.path(percentEncoded: false)))
        #expect(FileManager.default.directoryExists(at: legacyData))
        #expect(!keychainController.setRestorationTokenForUsernameCalled)
    }
    
    @Test
    func settingsAreNotReappliedWhenTheLegacyFileCannotBeRemoved() throws {
        try writeLegacyPreferences(["lastVersionLaunched": "25.09.12", "enableNotifications": false])
        try setLegacyPreferencesRemovable(false)
        #expect(migration.run() == .migrated)
        #expect(FileManager.default.fileExists(atPath: directories.legacyPreferences.path(percentEncoded: false)))
        suite.set("25.10.0", forKey: "lastVersionLaunched")
        suite.set(true, forKey: "enableNotifications")
        
        #expect(migration.run() == .nothingToMigrate)
        
        #expect(suite.string(forKey: "lastVersionLaunched") == "25.10.0")
        #expect(suite.object(forKey: "enableNotifications") as? Bool == true)
    }
    
    @Test
    func aLeftoverLegacyFileIsRemovedWithoutTouchingSettings() throws {
        try writeLegacyPreferences(["lastVersionLaunched": "25.09.12"])
        try setLegacyPreferencesRemovable(false)
        #expect(migration.run() == .migrated)
        suite.set("25.10.0", forKey: "lastVersionLaunched")
        try setLegacyPreferencesRemovable(true)
        
        #expect(migration.run() == .nothingToMigrate)
        
        #expect(!FileManager.default.fileExists(atPath: directories.legacyPreferences.path(percentEncoded: false)))
        #expect(suite.string(forKey: "lastVersionLaunched") == "25.10.0")
    }
    
    @Test
    func aLegacyFileRewrittenAfterItWasAppliedIsAppliedAgain() throws {
        try writeLegacyPreferences(["lastVersionLaunched": "25.09.12"])
        try setLegacyPreferencesRemovable(false)
        #expect(migration.run() == .migrated)
        suite.set("25.10.0", forKey: "lastVersionLaunched")
        // An unentitled build ran again and wrote over the file that could not be removed.
        try setLegacyPreferencesRemovable(true)
        try writeLegacyPreferences(["lastVersionLaunched": "25.10.0", "enableNotifications": false])
        try setLegacyPreferencesRemovable(false)
        
        #expect(migration.run() == .migrated)
        
        #expect(suite.string(forKey: "lastVersionLaunched") == "25.10.0")
        #expect(suite.object(forKey: "enableNotifications") as? Bool == false)
        
        suite.set("25.10.2", forKey: "lastVersionLaunched")
        #expect(migration.run() == .nothingToMigrate)
        #expect(suite.string(forKey: "lastVersionLaunched") == "25.10.2")
    }
    
    @Test
    func logEntriesGoToTheInjectedSink() throws {
        try writeLegacyPreferences(["lastVersionLaunched": "25.09.12"])
        try setLegacyPreferencesRemovable(false)
        
        #expect(migration.run() == .migrated)
        
        #expect(logEntries.count == 2)
        guard case .error(let message) = logEntries.first else {
            Issue.record("Expected an error entry, got \(logEntries)")
            return
        }
        #expect(message.hasPrefix("Failed removing the legacy settings"), Comment(rawValue: message))
        #expect(logEntries.last == .info("App group migration: migrated"))
    }
    
    @Test
    func thePreferencesStepLeavesSessionsForTheSecondStep() throws {
        try writeLegacyPreferences(["lastVersionLaunched": "25.09.12"])
        let legacyData = try makeStore(in: directories.legacySessions)
        storedTokens[userID] = makeToken(dataDirectory: legacyData)
        
        let preferences = migration.migratePreferences()
        
        #expect(preferences == .migrated)
        #expect(suite.string(forKey: "lastVersionLaunched") == "25.09.12")
        #expect(FileManager.default.directoryExists(at: legacyData))
        #expect(!keychainController.setRestorationTokenForUsernameCalled)
        #expect(logEntries == [])
        
        #expect(migration.finish(preferences: preferences) == .migrated)
        
        #expect(!FileManager.default.directoryExists(at: legacyData))
        #expect(logEntries == [.info("App group migration: migrated")])
    }
    
    // MARK: - Sessions
    
    @Test
    func legacySessionMovesIntoTheGroupAndTheTokenFollows() throws {
        let legacyData = try makeStore(in: directories.legacySessions)
        let name = legacyData.lastPathComponent
        let legacyCache = directories.legacySessionCaches.appending(component: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: legacyCache, withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: legacyCache.appending(component: "matrix-sdk-event-cache.sqlite3"))
        // Written by a previous install of the app, whose container path has since changed.
        let staleData = root.appending(path: "OldContainer/Library/Application Support/test/Sessions/\(name)", directoryHint: .isDirectory)
        let original = makeToken(dataDirectory: staleData)
        storedTokens[userID] = original
        
        #expect(migration.run() == .migrated)
        
        let data = directories.sessions.appending(component: name, directoryHint: .isDirectory)
        let cache = directories.sessionCaches.appending(component: name, directoryHint: .isDirectory)
        #expect(FileManager.default.fileExists(atPath: data.appending(component: "matrix-sdk-crypto.sqlite3").path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: cache.appending(component: "matrix-sdk-event-cache.sqlite3").path(percentEncoded: false)))
        #expect(!FileManager.default.directoryExists(at: legacyData))
        #expect(!FileManager.default.directoryExists(at: legacyCache))
        
        let migrated = try #require(storedTokens[userID])
        #expect(migrated.sessionDirectories == SessionDirectories(dataDirectory: data, cacheDirectory: cache))
        #expect(migrated.session == original.session)
        #expect(migrated.passphrase == original.passphrase)
        #expect(migrated.pusherNotificationClientIdentifier == original.pusherNotificationClientIdentifier)
    }
    
    @Test
    func dataAlreadyInTheGroupIsAdoptedAfterAnInterruptedRun() throws {
        let data = try makeStore(in: directories.sessions)
        let name = data.lastPathComponent
        storedTokens[userID] = makeToken(dataDirectory: directories.legacySessions.appending(component: name, directoryHint: .isDirectory))
        
        #expect(migration.run() == .migrated)
        
        #expect(storedTokens[userID]?.sessionDirectories.dataDirectory == data)
        #expect(FileManager.default.directoryExists(at: data))
    }
    
    @Test
    func tokenWithoutAStoreIsLeftAlone() {
        let token = makeToken(dataDirectory: directories.legacySessions.appending(component: UUID().uuidString, directoryHint: .isDirectory))
        storedTokens[userID] = token
        
        #expect(migration.run() == .nothingToMigrate)
        
        #expect(storedTokens[userID] == token)
        #expect(!keychainController.setRestorationTokenForUsernameCalled)
    }
    
    @Test
    func migratedTokenSurvivesTheKeychainRoundTrip() throws {
        let keychain = KeychainController(service: .tests, accessGroup: InfoPlistReader.main.keychainAccessGroupIdentifier)
        keychain.removeAllRestorationTokens()
        defer { keychain.removeAllRestorationTokens() }
        let legacyData = try makeStore(in: directories.legacySessions)
        keychain.setRestorationToken(makeToken(dataDirectory: legacyData), forUsername: userID)
        
        let outcome = AppGroupMigration(directories: directories, suiteName: suiteName, keychainController: keychain) { _ in }.run()
        
        #expect(outcome == .migrated)
        #expect(keychain.restorationTokenForUsername(userID)?.sessionDirectories.dataDirectory == directories.sessions.appending(component: legacyData.lastPathComponent, directoryHint: .isDirectory))
    }
    
    @Test
    func dataIsPutBackWhenTheTokenCannotBeUpdated() throws {
        keychainController.setRestorationTokenForUsernameClosure = { _, _ in }
        let legacyData = try makeStore(in: directories.legacySessions)
        let token = makeToken(dataDirectory: legacyData)
        storedTokens[userID] = token
        
        #expect(migration.run() == .deferred)
        
        #expect(logEntries == [.error("Failed updating the restoration token"), .info("App group migration: deferred")])
        
        #expect(FileManager.default.fileExists(atPath: legacyData.appending(component: "matrix-sdk-crypto.sqlite3").path(percentEncoded: false)))
        #expect(!FileManager.default.directoryExists(at: directories.sessions.appending(component: legacyData.lastPathComponent)))
        #expect(storedTokens[userID] == token)
    }
    
    @Test
    func dataStaysInTheGroupWhenTheUpdatedTokenCannotBeReadBack() throws {
        let legacyData = try makeStore(in: directories.legacySessions)
        storedTokens[userID] = makeToken(dataDirectory: legacyData)
        keychainController.setRestorationTokenForUsernameClosure = { [unowned self] token, userID in
            storedTokens[userID] = token
            keychainController.restorationTokensClosure = { [] }
        }
        
        #expect(migration.run() == .deferred)
        
        #expect(logEntries == [.error("Failed updating the restoration token"), .info("App group migration: deferred")])
        
        let data = directories.sessions.appending(component: legacyData.lastPathComponent, directoryHint: .isDirectory)
        #expect(FileManager.default.fileExists(atPath: data.appending(component: "matrix-sdk-crypto.sqlite3").path(percentEncoded: false)))
        #expect(storedTokens[userID]?.sessionDirectories.dataDirectory == data)
    }
    
    @Test
    func existingGroupDataIsNeverOverwritten() throws {
        let data = try makeStore(in: directories.sessions)
        let legacyData = directories.legacySessions.appending(component: data.lastPathComponent, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: legacyData, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: legacyData.appending(component: "matrix-sdk-crypto.sqlite3"))
        storedTokens[userID] = makeToken(dataDirectory: legacyData)
        
        #expect(migration.run() == .migrated)
        
        #expect(try Data(contentsOf: data.appending(component: "matrix-sdk-crypto.sqlite3")) == Data("crypto".utf8))
        #expect(try Data(contentsOf: legacyData.appending(component: "matrix-sdk-crypto.sqlite3")) == Data("legacy".utf8))
        #expect(storedTokens[userID]?.sessionDirectories.dataDirectory == data)
    }
    
    // MARK: - Repeated launches
    
    @Test
    func nothingLeftBehindIsANoOp() throws {
        let data = try makeStore(in: directories.sessions)
        let token = makeToken(dataDirectory: data)
        storedTokens[userID] = token
        
        #expect(migration.run() == .nothingToMigrate)
        
        #expect(storedTokens[userID] == token)
        #expect(!keychainController.setRestorationTokenForUsernameCalled)
    }
    
    @Test
    func secondRunChangesNothing() throws {
        try writeLegacyPreferences(["lastVersionLaunched": "25.09.12"])
        storedTokens[userID] = try makeToken(dataDirectory: makeStore(in: directories.legacySessions))
        #expect(migration.run() == .migrated)
        let migratedToken = storedTokens[userID]
        suite.set("25.10.0", forKey: "lastVersionLaunched")
        
        #expect(migration.run() == .nothingToMigrate)
        
        #expect(storedTokens[userID] == migratedToken)
        #expect(keychainController.setRestorationTokenForUsernameCallsCount == 1)
        #expect(suite.string(forKey: "lastVersionLaunched") == "25.10.0")
    }
    
    // MARK: - Helpers
    
    private func writeLegacyPreferences(_ values: [String: Any]) throws {
        try FileManager.default.createDirectory(at: directories.legacyPreferences.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0).write(to: directories.legacyPreferences)
    }
    
    /// Removing a file needs write access to its directory, so this toggles the parent's.
    private func setLegacyPreferencesRemovable(_ removable: Bool) throws {
        try FileManager.default.setAttributes([.posixPermissions: removable ? 0o755 : 0o555],
                                              ofItemAtPath: directories.legacyPreferences.deletingLastPathComponent().path(percentEncoded: false))
    }
    
    private func makeStore(in sessions: URL) throws -> URL {
        let directory = sessions.appending(component: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("crypto".utf8).write(to: directory.appending(component: "matrix-sdk-crypto.sqlite3"))
        return directory
    }
    
    private func makeToken(dataDirectory: URL) -> RestorationToken {
        RestorationToken(session: Session(accessToken: "accessToken",
                                          refreshToken: "refreshToken",
                                          userId: userID,
                                          deviceId: "DEVICE",
                                          homeserverUrl: "https://matrix.example.com",
                                          oauthData: nil,
                                          slidingSyncVersion: .native),
                         sessionDirectories: SessionDirectories(dataDirectory: dataDirectory,
                                                                cacheDirectory: directories.legacySessionCaches.appending(component: dataDirectory.lastPathComponent,
                                                                                                                          directoryHint: .isDirectory)),
                         passphrase: RestorationTokenFixtures.passphrase,
                         pusherNotificationClientIdentifier: "pusherClientID")
    }
}
