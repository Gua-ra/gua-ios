//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import CryptoKit
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

    /// MXLog drops messages until it is configured, so an early caller buffers these.
    enum LogEntry: Equatable {
        case info(String)
        case error(String)

        func writeToMXLog() {
            switch self {
            case .info(let message): MXLog.info(message)
            case .error(let message): MXLog.error(message)
            }
        }
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
    let log: (LogEntry) -> Void

    private static let appliedLegacyPreferencesDigestKey = "guaAppGroupMigration.appliedLegacyPreferencesDigest"

    static func live(log: @escaping (LogEntry) -> Void) -> AppGroupMigration? {
        let suiteName = InfoPlistReader.main.appGroupIdentifier
        guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName) != nil else {
            return nil
        }

        let legacyRoot = URL.applicationSupportDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let baseBundleIdentifier = InfoPlistReader.main.baseBundleIdentifier
        let directories = Directories(legacyPreferences: legacyRoot.appending(path: "Library/Preferences/\(suiteName).plist"),
                                      legacySessions: legacyRoot.appending(path: "Library/Application Support/\(baseBundleIdentifier)/Sessions", directoryHint: .isDirectory),
                                      legacySessionCaches: legacyRoot.appending(path: "Library/Caches/\(baseBundleIdentifier)/Sessions", directoryHint: .isDirectory),
                                      sessions: .sessionsBaseDirectory,
                                      sessionCaches: .sessionCachesBaseDirectory)
        let keychainController = KeychainController(service: .sessions, accessGroup: InfoPlistReader.main.keychainAccessGroupIdentifier)

        return AppGroupMigration(directories: directories, suiteName: suiteName, keychainController: keychainController, log: log)
    }

    func run() -> Outcome {
        finish(preferences: migratePreferences())
    }

    func finish(preferences: Outcome) -> Outcome {
        let sessions = preferences == .deferred ? .deferred : migrateSessions()
        var outcome = Outcome.nothingToMigrate
        if preferences == .deferred || sessions == .deferred {
            outcome = .deferred
        } else if preferences == .migrated || sessions == .migrated {
            outcome = .migrated
        }
        if outcome != .nothingToMigrate {
            log(.info("App group migration: \(outcome)"))
        }
        return outcome
    }

    /// The legacy suite replaces the group one: a file not applied before only exists when an
    /// unentitled build ran after the group suite was last written.
    func migratePreferences() -> Outcome {
        let url = directories.legacyPreferences
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return .nothingToMigrate }
        guard let data = try? Data(contentsOf: url) else { return .deferred }

        guard let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let suite = UserDefaults(suiteName: suiteName) else {
            log(.error("Legacy settings are not a property list, leaving them in place"))
            return .nothingToMigrate
        }

        // A file that outlived its removal must not overwrite settings changed since it was
        // applied. A different file means an unentitled build ran again, so it still wins.
        let digest = Data(SHA256.hash(data: data))
        guard suite.data(forKey: Self.appliedLegacyPreferencesDigestKey) != digest else {
            removeLegacyPreferences()
            return .nothingToMigrate
        }

        suite.setPersistentDomain(values, forName: suiteName)
        guard NSDictionary(dictionary: suite.persistentDomain(forName: suiteName) ?? [:]).isEqual(to: values) else {
            log(.error("Copying the legacy settings into the app group failed"))
            return .deferred
        }
        // Only after the comparison above, which needs the domain to hold exactly `values`.
        suite.set(digest, forKey: Self.appliedLegacyPreferencesDigestKey)

        removeLegacyPreferences()
        return .migrated
    }

    // MARK: - Private

    private func removeLegacyPreferences() {
        do {
            try fileManager.removeItem(at: directories.legacyPreferences)
        } catch {
            log(.error("Failed removing the legacy settings: \(error)"))
        }
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
                    log(.error("Failed moving session data into the app group: \(error)"))
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
                log(.error("Failed updating the restoration token"))
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
