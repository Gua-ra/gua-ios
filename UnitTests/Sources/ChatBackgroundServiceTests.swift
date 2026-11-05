//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import XCTest

@MainActor
final class ChatBackgroundServiceTests: XCTestCase {
    private let roomID = "!room:gua.global"

    private var roomStateClient: RoomStateClientMock!
    private var cache: InMemoryChatBackgroundCache!
    private var roomProxy: JoinedRoomProxyMock!
    private var service: ChatBackgroundService!

    override func setUp() {
        roomStateClient = RoomStateClientMock()
        roomStateClient.chatBackgroundRoomIDReturnValue = .notFound
        cache = InMemoryChatBackgroundCache()
        roomProxy = JoinedRoomProxyMock(.init(id: roomID))
        roomProxy.sendStateEventTypeStateKeyContentReturnValue = .success("$sent")
        service = ChatBackgroundService(roomStateClient: roomStateClient, cache: cache)
    }

    func testCachedBackgroundIsEmittedFirst() {
        cache.values[roomID] = stored(.preset(.aurora), eventID: "$cached", timestamp: 10)

        XCTAssertEqual(service.backgroundPublisher(roomID: roomID).value, .preset(.aurora))
        XCTAssertEqual(service.backgroundPublisher(roomID: "!other:gua.global").value, .none)
    }

    func testServerStateReplacesTheCacheWhateverItsTimestamp() async {
        cache.values[roomID] = stored(.preset(.aurora), eventID: "$cached", timestamp: 500)
        roomStateClient.chatBackgroundRoomIDReturnValue = .found(stored(.preset(.mint), eventID: "$server", timestamp: 100))

        await service.refresh(roomID: roomID)

        XCTAssertEqual(service.backgroundPublisher(roomID: roomID).value, .preset(.mint))
        XCTAssertEqual(cache.saved.last?.roomID, roomID)
        XCTAssertEqual(cache.saved.last?.value.eventID, "$server")
    }

    func testNotFoundMeansNoBackground() async {
        cache.values[roomID] = stored(.preset(.aurora), eventID: "$cached", timestamp: 10)
        roomStateClient.chatBackgroundRoomIDReturnValue = .notFound

        await service.refresh(roomID: roomID)

        XCTAssertEqual(service.backgroundPublisher(roomID: roomID).value, .none)
    }

    func testServerErrorsKeepTheCache() async {
        cache.values[roomID] = stored(.preset(.aurora), eventID: "$cached", timestamp: 10)

        for error in [RoomStateClientError.server(status: 500), .unauthorized, .transport] {
            roomStateClient.chatBackgroundRoomIDReturnValue = .failed(error)
            await service.refresh(roomID: roomID)
            XCTAssertEqual(service.backgroundPublisher(roomID: roomID).value, .preset(.aurora), "\(error)")
        }
        XCTAssertTrue(cache.saved.isEmpty)
    }

    func testReadingTheServerKeepsAnUnchangedChatInTheCache() async {
        let value = stored(.preset(.sky), eventID: "$server", timestamp: 100)
        cache.values[roomID] = value
        roomStateClient.chatBackgroundRoomIDReturnValue = .found(value)

        await service.refresh(roomID: roomID)

        XCTAssertEqual(cache.saved.map(\.value), [value])
    }

    func testNewerTimelineEventIsApplied() {
        cache.values[roomID] = stored(.preset(.aurora), eventID: "$old", timestamp: 100)

        service.handleTimelineEvent(roomID: roomID, eventID: "$new", timestamp: 200, contentJSON: ChatBackground.preset(.ocean).contentJSON)

        XCTAssertEqual(service.backgroundPublisher(roomID: roomID).value, .preset(.ocean))
        XCTAssertEqual(cache.saved.last?.value.timestamp, 200)
    }

    func testOlderTimelineEventIsIgnored() {
        cache.values[roomID] = stored(.preset(.aurora), eventID: "$current", timestamp: 200)

        service.handleTimelineEvent(roomID: roomID, eventID: "$older", timestamp: 100, contentJSON: ChatBackground.preset(.ocean).contentJSON)

        XCTAssertEqual(service.backgroundPublisher(roomID: roomID).value, .preset(.aurora))
        XCTAssertTrue(cache.saved.isEmpty)
    }

    func testTimelineRemovalClearsTheBackground() {
        cache.values[roomID] = stored(.preset(.aurora), eventID: "$current", timestamp: 100)

        service.handleTimelineEvent(roomID: roomID, eventID: "$removed", timestamp: 200, contentJSON: "{}")

        XCTAssertEqual(service.backgroundPublisher(roomID: roomID).value, .none)
    }

    func testSendAppliesALocalEchoStampedAfterTheCurrentValue() async throws {
        cache.values[roomID] = stored(.preset(.aurora), eventID: "$current", timestamp: 1000)

        let result = await service.set(.preset(.night), roomProxy: roomProxy)

        XCTAssertNoThrow(try result.get())
        XCTAssertEqual(roomProxy.sendStateEventTypeStateKeyContentReceivedArguments?.type, "global.gua.room.background")
        XCTAssertEqual(roomProxy.sendStateEventTypeStateKeyContentReceivedArguments?.stateKey, "")
        XCTAssertEqual(roomProxy.sendStateEventTypeStateKeyContentReceivedArguments?.content, ChatBackground.preset(.night).contentJSON)
        XCTAssertEqual(service.backgroundPublisher(roomID: roomID).value, .preset(.night))
        let echo = try XCTUnwrap(cache.saved.last?.value)
        XCTAssertEqual(echo.eventID, "$sent")
        XCTAssertEqual(echo.timestamp, 1001)
    }

    func testLocalEchoIsReplacedByItsOwnTimelineEvent() async {
        cache.values[roomID] = stored(.preset(.aurora), eventID: "$current", timestamp: 1000)
        _ = await service.set(.preset(.night), roomProxy: roomProxy)

        // The server's clock can be behind the stamp's, and the event must still win.
        service.handleTimelineEvent(roomID: roomID, eventID: "$sent", timestamp: 900, contentJSON: ChatBackground.preset(.night).contentJSON)
        XCTAssertEqual(cache.saved.last?.value.timestamp, 900)

        service.handleTimelineEvent(roomID: roomID, eventID: "$between", timestamp: 950, contentJSON: ChatBackground.preset(.sand).contentJSON)
        XCTAssertEqual(service.backgroundPublisher(roomID: roomID).value, .preset(.sand))
    }

    func testFailedSendChangesNothing() async {
        cache.values[roomID] = stored(.preset(.aurora), eventID: "$current", timestamp: 1000)
        roomProxy.sendStateEventTypeStateKeyContentReturnValue = .failure(.sdkError(RoomProxyMockError.generic))

        let result = await service.set(.preset(.night), roomProxy: roomProxy)

        guard case .failure = result else {
            XCTFail("The send should fail")
            return
        }
        XCTAssertEqual(service.backgroundPublisher(roomID: roomID).value, .preset(.aurora))
        XCTAssertTrue(cache.saved.isEmpty)
    }

    func testRemoveSendsEmptyContent() async {
        cache.values[roomID] = stored(.preset(.aurora), eventID: "$current", timestamp: 1000)

        _ = await service.remove(roomProxy: roomProxy)

        XCTAssertEqual(roomProxy.sendStateEventTypeStateKeyContentReceivedArguments?.content, "{}")
        XCTAssertEqual(service.backgroundPublisher(roomID: roomID).value, .none)
    }

    func testUnconfirmedSendOutlivesAServerReplyReadBeforeIt() async {
        cache.values[roomID] = stored(.preset(.aurora), eventID: "$current", timestamp: 1000)
        let reply = stored(.preset(.aurora), eventID: "$current", timestamp: 1000)
        let roomProxy: JoinedRoomProxyMock = roomProxy
        roomStateClient.chatBackgroundRoomIDClosure = { [service] _ in
            _ = await service?.set(.preset(.night), roomProxy: roomProxy)
            return .found(reply)
        }

        await service.refresh(roomID: roomID)

        XCTAssertEqual(service.backgroundPublisher(roomID: roomID).value, .preset(.night))
    }

    func testNewerTimelineEventOutlivesAServerReplyReadBeforeIt() async {
        let reply = stored(.preset(.aurora), eventID: "$older", timestamp: 1000)
        let newer = ChatBackground.preset(.lavender).contentJSON
        roomStateClient.chatBackgroundRoomIDClosure = { [service, roomID] _ in
            await service?.handleTimelineEvent(roomID: roomID, eventID: "$newer", timestamp: 2000, contentJSON: newer)
            return .found(reply)
        }

        await service.refresh(roomID: roomID)

        XCTAssertEqual(service.backgroundPublisher(roomID: roomID).value, .preset(.lavender))
    }

    func testServerReplyWinsOverAnOlderTimelineEventSeenWhileReading() async {
        let reply = stored(.preset(.graphite), eventID: "$newer", timestamp: 2000)
        let older = ChatBackground.preset(.lavender).contentJSON
        roomStateClient.chatBackgroundRoomIDClosure = { [service, roomID] _ in
            await service?.handleTimelineEvent(roomID: roomID, eventID: "$older", timestamp: 1000, contentJSON: older)
            return .found(reply)
        }

        await service.refresh(roomID: roomID)

        XCTAssertEqual(service.backgroundPublisher(roomID: roomID).value, .preset(.graphite))
    }

    func testCacheKeepsTheMostRecentlyUsedRoomsOnDisk() {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let diskCache = ChatBackgroundCache(directory: directory)
        for index in 0...ChatBackgroundCache.maxRooms {
            diskCache.save(stored(.preset(.mint), eventID: "$\(index)", timestamp: UInt64(index)), roomID: "!\(index):gua.global")
        }
        diskCache.save(stored(.preset(.sky), eventID: "$again", timestamp: 1), roomID: "!1:gua.global")

        let loaded = diskCache.load()
        XCTAssertEqual(loaded.count, ChatBackgroundCache.maxRooms)
        XCTAssertNil(loaded["!0:gua.global"])
        XCTAssertEqual(loaded["!1:gua.global"]?.eventID, "$again")

        // Writes happen in the background, so the file is read until the last one has landed.
        var reloaded: [String: ChatBackgroundStoredValue] = [:]
        for _ in 0..<250 where reloaded["!1:gua.global"]?.eventID != "$again" {
            Thread.sleep(forTimeInterval: 0.02)
            reloaded = ChatBackgroundCache(directory: directory).load()
        }
        XCTAssertEqual(reloaded.count, ChatBackgroundCache.maxRooms)
        XCTAssertEqual(reloaded["!1:gua.global"]?.eventID, "$again")
    }

    private func stored(_ background: ChatBackground, eventID: String?, timestamp: UInt64) -> ChatBackgroundStoredValue {
        ChatBackgroundStoredValue(contentJSON: background.contentJSON, eventID: eventID, timestamp: timestamp)
    }
}

@MainActor
private final class InMemoryChatBackgroundCache: ChatBackgroundCacheProtocol {
    var values: [String: ChatBackgroundStoredValue] = [:]
    private(set) var saved: [(roomID: String, value: ChatBackgroundStoredValue)] = []

    func load() -> [String: ChatBackgroundStoredValue] {
        values
    }

    func save(_ value: ChatBackgroundStoredValue, roomID: String) {
        saved.append((roomID, value))
    }
}
