//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// Keychain items stay put: without `keychain-access-groups` the app writes to its application
/// identifier, which equals the shared access group.
struct AppGroupMigration {
    enum Outcome: Equatable {
        case nothingToMigrate
        case migrated
        /// Legacy state could not be moved yet, for example before first unlock. The settings
        /// suite is not authoritative until a later launch moves it.
        case deferred
    }

    struct Directories {
        let legacyPreferences: URL
        let legacySessions: URL
        let legacySessionCaches: URL
        let sessions: URL
        let sessionCaches: URL
    }

    let directories: Directories
    let suiteName: String
    let keychainController: KeychainControllerProtocol

    static func runIfNeeded() -> Outcome {
        let suiteName = InfoPlistReader.main.appGroupIdentifier
        guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName) != nil else {
            return .nothingToMigrate
        }

        let legacyRoot = URL.applicationSupportDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let baseBundleIdentifier = InfoPlistReader.main.baseBundleIdentifier
        let directories = Directories(legacyPreferences: legacyRoot.appending(path: "Library/Preferences/\(suiteName).plist"),
                                      legacySessions: legacyRoot.appending(path: "Library/Application Support/\(baseBundleIdentifier)/Sessions", directoryHint: .isDirectory),
                                      legacySessionCaches: legacyRoot.appending(path: "Library/Caches/\(baseBundleIdentifier)/Sessions", directoryHint: .isDirectory),
                                      sessions: .sessionsBaseDirectory,
                                      sessionCaches: .sessionCachesBaseDirectory)
        let keychainController = KeychainController(service: .sessions, accessGroup: InfoPlistReader.main.keychainAccessGroupIdentifier)

        let outcome = AppGroupMigration(directories: directories, suiteName: suiteName, keychainController: keychainController).run()
        if outcome != .nothingToMigrate {
            MXLog.info("App group migration: \(outcome)")
        }
        return outcome
    }

    func run() -> Outcome {
        let preferences = migratePreferences()
        guard preferences != .deferred else { return .deferred }
        let sessions = migrateSessions()
        guard sessions != .deferred else { return .deferred }
        return preferences == .migrated || sessions == .migrated ? .migrated : .nothingToMigrate
    }

    // MARK: - Private

    /// The legacy suite replaces the group one: it only exists when an unentitled build ran after
    /// the group suite was last written.
    private func migratePreferences() -> Outcome {
        let url = directories.legacyPreferences
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return .nothingToMigrate }
        guard let data = try? Data(contentsOf: url) else { return .deferred }

        guard let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let suite = UserDefaults(suiteName: suiteName) else {
            MXLog.error("Legacy settings are not a property list, leaving them in place")
            return .nothingToMigrate
        }

        suite.setPersistentDomain(values, forName: suiteName)
        guard NSDictionary(dictionary: suite.persistentDomain(forName: suiteName) ?? [:]).isEqual(to: values) else {
            MXLog.error("Copying the legacy settings into the app group failed")
            return .deferred
        }

        do {
            try fileManager.removeItem(at: url)
        } catch {
            MXLog.error("Failed removing the legacy settings: \(error)")
        }
        return .migrated
    }

    /// Both containers are on the data volume, so each move is an atomic rename.
    private func migrateSessions() -> Outcome {
        var outcome = Outcome.nothingToMigrate

        for credentials in keychainController.restorationTokens() {
            let token = credentials.restorationToken
            let name = token.sessionDirectories.dataDirectory.lastPathComponent
            let data = directories.sessions.appending(component: name, directoryHint: .isDirectory)
            let cache = directories.sessionCaches.appending(component: name, directoryHint: .isDirectory)
            guard !isSameLocation(token.sessionDirectories.dataDirectory, data) else { continue }

            let legacyData = directories.legacySessions.appending(component: name, directoryHint: .isDirectory)
            let needsMove = !fileManager.directoryExists(at: data)
            let store = SessionDirectories(dataDirectory: needsMove ? legacyData : data, cacheDirectory: cache)
            guard store.isNonTransientUserDataValid() else { continue }

            if needsMove {
                do {
                    try fileManager.createDirectoryIfNeeded(at: directories.sessions)
                    try fileManager.moveItem(at: legacyData, to: data)
                } catch {
                    MXLog.error("Failed moving session data into the app group: \(error)")
                    return .deferred
                }
            }

            let legacyCache = directories.legacySessionCaches.appending(component: name, directoryHint: .isDirectory)
            if fileManager.directoryExists(at: legacyCache), !fileManager.directoryExists(at: cache) {
                // Caches are rebuilt by the SDK, so a failed move only costs a refetch.
                try? fileManager.createDirectoryIfNeeded(at: directories.sessionCaches)
                try? fileManager.moveItem(at: legacyCache, to: cache)
            }

            let migratedToken = RestorationToken(session: token.session,
                                                 sessionDirectories: SessionDirectories(dataDirectory: data, cacheDirectory: cache),
                                                 passphrase: token.passphrase,
                                                 pusherNotificationClientIdentifier: token.pusherNotificationClientIdentifier)
            keychainController.setRestorationToken(migratedToken, forUsername: credentials.userID)

            // A failed restore deletes the token, so the data must stay where the stored token
            // points. Without a stored token, a later run adopts the data left in the group.
            let stored = keychainController.restorationTokens().first { $0.userID == credentials.userID }?.restorationToken
            guard let stored, isSameLocation(stored.sessionDirectories.dataDirectory, data) else {
                MXLog.error("Failed updating the restoration token")
                if stored != nil, needsMove {
                    try? fileManager.moveItem(at: data, to: legacyData)
                }
                return .deferred
            }
            outcome = .migrated
        }

        return outcome
    }

    private var fileManager: FileManager {
        .default
    }

    private func isSameLocation(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().pathComponents == rhs.resolvingSymlinksInPath().pathComponents
    }
}
