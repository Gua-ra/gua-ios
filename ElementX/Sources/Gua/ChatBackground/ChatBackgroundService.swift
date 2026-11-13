//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import MatrixRustSDK

// sourcery: AutoMockable
protocol ChatBackgroundServiceProtocol: AnyObject {
    @MainActor func themePublisher(roomID: String) -> CurrentValuePublisher<ChatTheme, Never>

    /// Reads the server's state, which replaces the current value unless something newer arrived meanwhile.
    @MainActor func refresh(roomID: String) async

    /// Applies only if newer than the current theme, so old events reached by scrolling back are ignored.
    @MainActor func handleTimelineEvent(roomID: String, eventID: String, timestamp: UInt64, contentJSON: String)

    /// A photo must be uploaded first.
    @MainActor func set(_ theme: ChatTheme, roomProxy: JoinedRoomProxyProtocol) async -> Result<Void, RoomProxyError>

    @MainActor var defaultThemePublisher: CurrentValuePublisher<ChatTheme, Never> { get }

    /// Shows the new theme straight away, and puts the previous one back if the write fails. A photo must be uploaded first.
    @MainActor func setDefaultTheme(_ theme: ChatTheme) async -> Result<Void, ClientProxyError>
}

extension StateEventType {
    static var guaChatBackground: StateEventType {
        .custom(value: ChatBackground.eventType)
    }
}

@MainActor
final class ChatBackgroundService: ChatBackgroundServiceProtocol {
    private struct Slot {
        var stored: ChatBackgroundStoredValue?
        /// Counts changes from this device and the timeline, so a server reply in flight meanwhile can tell it is stale.
        var localRevision = 0
        var pendingEventID: String?

        func outlives(_ reply: ChatBackgroundStoredValue) -> Bool {
            guard let stored, stored.eventID != reply.eventID else { return false }
            return (pendingEventID != nil && stored.eventID == pendingEventID) || stored.timestamp > reply.timestamp
        }
    }

    private let roomStateClient: RoomStateClientProtocol
    private let cache: ChatBackgroundCacheProtocol
    private let defaultThemeSetting: DefaultChatThemeSetting

    private lazy var cachedValues = cache.load()
    private var slots: [String: Slot] = [:]
    private var subjects: [String: CurrentValueSubject<ChatTheme, Never>] = [:]

    init(roomStateClient: RoomStateClientProtocol, cache: ChatBackgroundCacheProtocol, defaultThemeSetting: DefaultChatThemeSetting) {
        self.roomStateClient = roomStateClient
        self.cache = cache
        self.defaultThemeSetting = defaultThemeSetting
    }

    func themePublisher(roomID: String) -> CurrentValuePublisher<ChatTheme, Never> {
        subject(roomID: roomID).asCurrentValuePublisher()
    }

    var defaultThemePublisher: CurrentValuePublisher<ChatTheme, Never> {
        defaultThemeSetting.themePublisher
    }

    func setDefaultTheme(_ theme: ChatTheme) async -> Result<Void, ClientProxyError> {
        await defaultThemeSetting.set(theme)
    }

    func refresh(roomID: String) async {
        let revisionAtStart = slot(roomID: roomID).localRevision

        let reply: ChatBackgroundStoredValue
        switch await roomStateClient.chatBackground(roomID: roomID) {
        case .found(let value):
            reply = value
        case .notFound:
            reply = ChatBackgroundStoredValue(contentJSON: ChatBackground.removedContent, eventID: nil, timestamp: 0)
        case .failed:
            return
        }

        // The server's state wins whatever its timestamp, and reading it keeps the chat in the cache.
        update(roomID: roomID, savingUnchanged: true) { current in
            if current.localRevision != revisionAtStart, current.outlives(reply) {
                return current
            }
            var updated = current
            updated.stored = reply
            updated.pendingEventID = nil
            return updated
        }
    }

    func handleTimelineEvent(roomID: String, eventID: String, timestamp: UInt64, contentJSON: String) {
        let candidate = ChatBackgroundStoredValue(contentJSON: contentJSON, eventID: eventID, timestamp: timestamp)

        update(roomID: roomID) { current in
            guard let stored = current.stored else {
                return Slot(stored: candidate, localRevision: current.localRevision + 1)
            }
            let accepted = if candidate.eventID == stored.eventID {
                // A copy of the same event can predate its redaction, so only its server timestamp is taken.
                ChatBackgroundStoredValue(contentJSON: stored.contentJSON, eventID: stored.eventID, timestamp: candidate.timestamp)
            } else if candidate.timestamp > stored.timestamp {
                candidate
            } else {
                stored
            }
            guard accepted != stored else { return current }
            return Slot(stored: accepted, localRevision: current.localRevision + 1)
        }
    }

    func set(_ theme: ChatTheme, roomProxy: JoinedRoomProxyProtocol) async -> Result<Void, RoomProxyError> {
        let content = theme.contentJSON

        switch await roomProxy.sendStateEvent(type: ChatBackground.eventType, stateKey: "", content: content) {
        case .success(let eventID):
            update(roomID: roomProxy.id) { current in
                // Never the device clock: one running ahead would make the next real change look older.
                let timestamp = (current.stored?.timestamp ?? 0) + 1
                return Slot(stored: ChatBackgroundStoredValue(contentJSON: content, eventID: eventID, timestamp: timestamp),
                            localRevision: current.localRevision + 1,
                            pendingEventID: eventID)
            }
            return .success(())
        case .failure(let error):
            MXLog.error("Failed sending the chat theme of \(roomProxy.id): \(error)")
            return .failure(error)
        }
    }

    private func slot(roomID: String) -> Slot {
        slots[roomID] ?? Slot(stored: cachedValues[roomID])
    }

    private func subject(roomID: String) -> CurrentValueSubject<ChatTheme, Never> {
        if let subject = subjects[roomID] {
            return subject
        }
        let subject = CurrentValueSubject<ChatTheme, Never>(ChatTheme(contentJSON: slot(roomID: roomID).stored?.contentJSON))
        subjects[roomID] = subject
        return subject
    }

    private func update(roomID: String, savingUnchanged: Bool = false, transform: (Slot) -> Slot) {
        let current = slot(roomID: roomID)
        let updated = transform(current)
        slots[roomID] = updated

        if let stored = updated.stored, savingUnchanged || stored != current.stored {
            cache.save(stored, roomID: roomID)
        }

        let theme = ChatTheme(contentJSON: updated.stored?.contentJSON)
        let subject = subject(roomID: roomID)
        if subject.value != theme {
            subject.send(theme)
        }
    }
}
