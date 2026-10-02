//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import MatrixRustSDK
import XCTest

final class AppGroupMigrationTests: XCTestCase {
    private let userID = "@alice:example.com"

    private var root: URL!
    private var directories: AppGroupMigration.Directories!
    private var suiteName: String!
    private var keychainController: KeychainControllerMock!
    private var storedTokens: [String: RestorationToken] = [:]

    private var migration: AppGroupMigration {
        AppGroupMigration(directories: directories, suiteName: suiteName, keychainController: keychainController)
    }

    private var suite: UserDefaults {
        UserDefaults(suiteName: suiteName)! // swiftlint:disable:this force_unwrapping
    }

    override func setUp() {
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
        keychainController = KeychainControllerMock()
        keychainController.restorationTokensClosure = { [unowned self] in
            storedTokens.map { KeychainCredentials(userID: $0.key, restorationToken: $0.value) }
        }
        keychainController.setRestorationTokenForUsernameClosure = { [unowned self] token, userID in
            storedTokens[userID] = token
        }
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: directories.legacyPreferences.path(percentEncoded: false))
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Settings

    func testLegacySettingsFillAnEmptyGroupSuite() throws {
        try writeLegacyPreferences(["lastVersionLaunched": "25.09.12", "enableNotifications": false])

        XCTAssertEqual(migration.run(), .migrated)

        XCTAssertEqual(suite.string(forKey: "lastVersionLaunched"), "25.09.12")
        XCTAssertEqual(suite.object(forKey: "enableNotifications") as? Bool, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directories.legacyPreferences.path(percentEncoded: false)))
    }

    func testLegacySettingsReplaceAStaleGroupSuite() throws {
        suite.set("25.08.1", forKey: "lastVersionLaunched")
        suite.set(true, forKey: "hasBootstrappedKeyStorage.@alice:example.com")
        try writeLegacyPreferences(["lastVersionLaunched": "25.09.12", "seenInvites": Data([1, 2, 3])])

        XCTAssertEqual(migration.run(), .migrated)

        XCTAssertEqual(suite.string(forKey: "lastVersionLaunched"), "25.09.12")
        XCTAssertEqual(suite.data(forKey: "seenInvites"), Data([1, 2, 3]))
        XCTAssertNil(suite.object(forKey: "hasBootstrappedKeyStorage.@alice:example.com"))
    }

    func testUnreadableLegacySettingsDeferWithoutTouchingAnything() throws {
        suite.set("25.08.1", forKey: "lastVersionLaunched")
        try writeLegacyPreferences(["lastVersionLaunched": "25.09.12"])
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: directories.legacyPreferences.path(percentEncoded: false))
        let legacyData = try makeStore(in: directories.legacySessions)
        storedTokens[userID] = makeToken(dataDirectory: legacyData)

        XCTAssertEqual(migration.run(), .deferred)

        XCTAssertEqual(suite.string(forKey: "lastVersionLaunched"), "25.08.1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directories.legacyPreferences.path(percentEncoded: false)))
        XCTAssertTrue(FileManager.default.directoryExists(at: legacyData))
        XCTAssertFalse(keychainController.setRestorationTokenForUsernameCalled)
    }

    // MARK: - Sessions

    func testLegacySessionMovesIntoTheGroupAndTheTokenFollows() throws {
        let legacyData = try makeStore(in: directories.legacySessions)
        let name = legacyData.lastPathComponent
        let legacyCache = directories.legacySessionCaches.appending(component: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: legacyCache, withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: legacyCache.appending(component: "matrix-sdk-event-cache.sqlite3"))
        // Written by a previous install of the app, whose container path has since changed.
        let staleData = root.appending(path: "OldContainer/Library/Application Support/test/Sessions/\(name)", directoryHint: .isDirectory)
        let original = makeToken(dataDirectory: staleData)
        storedTokens[userID] = original

        XCTAssertEqual(migration.run(), .migrated)

        let data = directories.sessions.appending(component: name, directoryHint: .isDirectory)
        let cache = directories.sessionCaches.appending(component: name, directoryHint: .isDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.appending(component: "matrix-sdk-crypto.sqlite3").path(percentEncoded: false)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appending(component: "matrix-sdk-event-cache.sqlite3").path(percentEncoded: false)))
        XCTAssertFalse(FileManager.default.directoryExists(at: legacyData))
        XCTAssertFalse(FileManager.default.directoryExists(at: legacyCache))

        let migrated = try XCTUnwrap(storedTokens[userID])
        XCTAssertEqual(migrated.sessionDirectories, SessionDirectories(dataDirectory: data, cacheDirectory: cache))
        XCTAssertEqual(migrated.session, original.session)
        XCTAssertEqual(migrated.passphrase, original.passphrase)
        XCTAssertEqual(migrated.pusherNotificationClientIdentifier, original.pusherNotificationClientIdentifier)
    }

    func testDataAlreadyInTheGroupIsAdoptedAfterAnInterruptedRun() throws {
        let data = try makeStore(in: directories.sessions)
        let name = data.lastPathComponent
        storedTokens[userID] = makeToken(dataDirectory: directories.legacySessions.appending(component: name, directoryHint: .isDirectory))

        XCTAssertEqual(migration.run(), .migrated)

        XCTAssertEqual(storedTokens[userID]?.sessionDirectories.dataDirectory, data)
        XCTAssertTrue(FileManager.default.directoryExists(at: data))
    }

    func testTokenWithoutAStoreIsLeftAlone() {
        let token = makeToken(dataDirectory: directories.legacySessions.appending(component: UUID().uuidString, directoryHint: .isDirectory))
        storedTokens[userID] = token

        XCTAssertEqual(migration.run(), .nothingToMigrate)

        XCTAssertEqual(storedTokens[userID], token)
        XCTAssertFalse(keychainController.setRestorationTokenForUsernameCalled)
    }

    func testMigratedTokenSurvivesTheKeychainRoundTrip() throws {
        let keychain = KeychainController(service: .tests, accessGroup: InfoPlistReader.main.keychainAccessGroupIdentifier)
        keychain.removeAllRestorationTokens()
        defer { keychain.removeAllRestorationTokens() }
        let legacyData = try makeStore(in: directories.legacySessions)
        keychain.setRestorationToken(makeToken(dataDirectory: legacyData), forUsername: userID)

        let outcome = AppGroupMigration(directories: directories, suiteName: suiteName, keychainController: keychain).run()

        XCTAssertEqual(outcome, .migrated)
        XCTAssertEqual(keychain.restorationTokenForUsername(userID)?.sessionDirectories.dataDirectory,
                       directories.sessions.appending(component: legacyData.lastPathComponent, directoryHint: .isDirectory))
    }

    func testDataIsPutBackWhenTheTokenCannotBeUpdated() throws {
        keychainController.setRestorationTokenForUsernameClosure = { _, _ in }
        let legacyData = try makeStore(in: directories.legacySessions)
        let token = makeToken(dataDirectory: legacyData)
        storedTokens[userID] = token

        XCTAssertEqual(migration.run(), .deferred)

        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyData.appending(component: "matrix-sdk-crypto.sqlite3").path(percentEncoded: false)))
        XCTAssertFalse(FileManager.default.directoryExists(at: directories.sessions.appending(component: legacyData.lastPathComponent)))
        XCTAssertEqual(storedTokens[userID], token)
    }

    func testDataStaysInTheGroupWhenTheUpdatedTokenCannotBeReadBack() throws {
        let legacyData = try makeStore(in: directories.legacySessions)
        storedTokens[userID] = makeToken(dataDirectory: legacyData)
        keychainController.setRestorationTokenForUsernameClosure = { [unowned self] token, userID in
            storedTokens[userID] = token
            keychainController.restorationTokensClosure = { [] }
        }

        XCTAssertEqual(migration.run(), .deferred)

        let data = directories.sessions.appending(component: legacyData.lastPathComponent, directoryHint: .isDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.appending(component: "matrix-sdk-crypto.sqlite3").path(percentEncoded: false)))
        XCTAssertEqual(storedTokens[userID]?.sessionDirectories.dataDirectory, data)
    }

    func testExistingGroupDataIsNeverOverwritten() throws {
        let data = try makeStore(in: directories.sessions)
        let legacyData = directories.legacySessions.appending(component: data.lastPathComponent, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: legacyData, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: legacyData.appending(component: "matrix-sdk-crypto.sqlite3"))
        storedTokens[userID] = makeToken(dataDirectory: legacyData)

        XCTAssertEqual(migration.run(), .migrated)

        XCTAssertEqual(try Data(contentsOf: data.appending(component: "matrix-sdk-crypto.sqlite3")), Data("crypto".utf8))
        XCTAssertEqual(try Data(contentsOf: legacyData.appending(component: "matrix-sdk-crypto.sqlite3")), Data("legacy".utf8))
        XCTAssertEqual(storedTokens[userID]?.sessionDirectories.dataDirectory, data)
    }

    // MARK: - Repeated launches

    func testNothingLeftBehindIsANoOp() throws {
        let data = try makeStore(in: directories.sessions)
        let token = makeToken(dataDirectory: data)
        storedTokens[userID] = token

        XCTAssertEqual(migration.run(), .nothingToMigrate)

        XCTAssertEqual(storedTokens[userID], token)
        XCTAssertFalse(keychainController.setRestorationTokenForUsernameCalled)
    }

    func testSecondRunChangesNothing() throws {
        try writeLegacyPreferences(["lastVersionLaunched": "25.09.12"])
        storedTokens[userID] = try makeToken(dataDirectory: makeStore(in: directories.legacySessions))
        XCTAssertEqual(migration.run(), .migrated)
        let migratedToken = storedTokens[userID]
        suite.set("25.10.0", forKey: "lastVersionLaunched")

        XCTAssertEqual(migration.run(), .nothingToMigrate)

        XCTAssertEqual(storedTokens[userID], migratedToken)
        XCTAssertEqual(keychainController.setRestorationTokenForUsernameCallsCount, 1)
        XCTAssertEqual(suite.string(forKey: "lastVersionLaunched"), "25.10.0")
    }

    // MARK: - Helpers

    private func writeLegacyPreferences(_ values: [String: Any]) throws {
        try FileManager.default.createDirectory(at: directories.legacyPreferences.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0).write(to: directories.legacyPreferences)
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
                         passphrase: "passphrase",
                         pusherNotificationClientIdentifier: "pusherClientID")
    }
}
