//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import MatrixRustSDK

enum ChatBackgroundServiceError: Error {
    case failedSending(RoomProxyError)
}

// sourcery: AutoMockable
protocol ChatBackgroundServiceProtocol: AnyObject {
    @MainActor func backgroundPublisher(roomID: String) -> CurrentValuePublisher<ChatBackground, Never>

    /// Reads the server's state, which replaces the current value unless something newer arrived meanwhile.
    @MainActor func refresh(roomID: String) async

    /// Applies only if newer than the current background, so old events reached by scrolling back are ignored.
    @MainActor func handleTimelineEvent(roomID: String, eventID: String, timestamp: UInt64, contentJSON: String)

    /// A photo must be uploaded first.
    @MainActor func set(_ background: ChatBackground, roomProxy: JoinedRoomProxyProtocol) async -> Result<Void, ChatBackgroundServiceError>
}

extension ChatBackgroundServiceProtocol {
    @MainActor func remove(roomProxy: JoinedRoomProxyProtocol) async -> Result<Void, ChatBackgroundServiceError> {
        await set(.none, roomProxy: roomProxy)
    }
}

extension StateEventType {
    /// The SDK 26.10 bindings build custom types with `stateEventTypeFromString(s:)` instead.
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
        /// A change sent from this device that neither the server nor the timeline has confirmed yet.
        var pendingEventID: String?

        func outlives(_ reply: ChatBackgroundStoredValue) -> Bool {
            guard let stored, stored.eventID != reply.eventID else { return false }
            return (pendingEventID != nil && stored.eventID == pendingEventID) || stored.timestamp > reply.timestamp
        }
    }

    private let roomStateClient: RoomStateClientProtocol
    private let cache: ChatBackgroundCacheProtocol

    private lazy var cachedValues = cache.load()
    private var slots: [String: Slot] = [:]
    private var subjects: [String: CurrentValueSubject<ChatBackground, Never>] = [:]

    nonisolated init(roomStateClient: RoomStateClientProtocol, cache: ChatBackgroundCacheProtocol) {
        self.roomStateClient = roomStateClient
        self.cache = cache
    }

    func backgroundPublisher(roomID: String) -> CurrentValuePublisher<ChatBackground, Never> {
        subject(roomID: roomID).asCurrentValuePublisher()
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
            let isNewer = if let stored = current.stored {
                candidate.eventID == stored.eventID || candidate.timestamp > stored.timestamp
            } else {
                true
            }
            guard isNewer, candidate != current.stored else { return current }
            return Slot(stored: candidate, localRevision: current.localRevision + 1)
        }
    }

    func set(_ background: ChatBackground, roomProxy: JoinedRoomProxyProtocol) async -> Result<Void, ChatBackgroundServiceError> {
        let content = background.contentJSON

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
            MXLog.error("Failed sending the chat background of \(roomProxy.id): \(error)")
            return .failure(.failedSending(error))
        }
    }

    private func slot(roomID: String) -> Slot {
        slots[roomID] ?? Slot(stored: cachedValues[roomID])
    }

    private func subject(roomID: String) -> CurrentValueSubject<ChatBackground, Never> {
        if let subject = subjects[roomID] {
            return subject
        }
        let subject = CurrentValueSubject<ChatBackground, Never>(ChatBackground(contentJSON: slot(roomID: roomID).stored?.contentJSON))
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

        let background = ChatBackground(contentJSON: updated.stored?.contentJSON)
        let subject = subject(roomID: roomID)
        if subject.value != background {
            subject.send(background)
        }
    }
}
