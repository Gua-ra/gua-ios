//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Foundation

struct ChatBackgroundStoredValue: Codable, Equatable {
    let contentJSON: String
    /// Nil for no event, or a server reply without one.
    let eventID: String?
    /// Server milliseconds, or the previous value plus 1 for a send the server has not echoed yet.
    let timestamp: UInt64

    enum CodingKeys: String, CodingKey {
        case contentJSON = "content"
        case eventID = "event_id"
        case timestamp = "ts"
    }
}

protocol ChatBackgroundCacheProtocol {
    @MainActor func load() -> [String: ChatBackgroundStoredValue]
    /// Stores the value as the most recently used entry, dropping the least recently used beyond the cap.
    @MainActor func save(_ value: ChatBackgroundStoredValue, roomID: String)

    @MainActor func loadDefaultTheme() -> String?
    @MainActor func saveDefaultTheme(_ contentJSON: String)
}

/// JSON files in the session's cache directory, which is deleted with the session.
@MainActor
final class ChatBackgroundCache: ChatBackgroundCacheProtocol {
    static let maxRooms = 500

    private struct Entry: Codable {
        let roomID: String
        let value: ChatBackgroundStoredValue
    }

    private let fileURL: URL
    private let defaultThemeFileURL: URL
    private let writeQueue = DispatchQueue(label: "global.gua.chat-background-cache", qos: .utility)
    private var entries: [Entry]?

    init(directory: URL) {
        fileURL = directory.appending(path: "chat-backgrounds.json")
        defaultThemeFileURL = directory.appending(path: "default-chat-theme.json")
    }

    func load() -> [String: ChatBackgroundStoredValue] {
        loadedEntries().reduce(into: [:]) { result, entry in
            result[entry.roomID] = result[entry.roomID] ?? entry.value
        }
    }

    func save(_ value: ChatBackgroundStoredValue, roomID: String) {
        let updated = Array(([Entry(roomID: roomID, value: value)] + loadedEntries().filter { $0.roomID != roomID }).prefix(Self.maxRooms))
        entries = updated

        guard let data = try? JSONEncoder().encode(updated) else { return }
        write(data, to: fileURL)
    }

    func loadDefaultTheme() -> String? {
        (try? Data(contentsOf: defaultThemeFileURL)).flatMap { String(data: $0, encoding: .utf8) }
    }

    func saveDefaultTheme(_ contentJSON: String) {
        write(Data(contentJSON.utf8), to: defaultThemeFileURL)
    }

    private func write(_ data: Data, to fileURL: URL) {
        writeQueue.async {
            // Never recreates the directory, so a write landing after sign-out deleted the session's caches fails.
            do {
                try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                MXLog.error("Failed writing the chat background cache: \(error)")
            }
        }
    }

    private func loadedEntries() -> [Entry] {
        if let entries {
            return entries
        }
        let loaded = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        entries = loaded
        return loaded
    }
}
