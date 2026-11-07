//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import Foundation
import MatrixRustSDK
import Synchronization
import Testing

struct PendingMediaBatchStoreTests {
    private let key = PendingMediaBatchStore.Key(roomID: "!room:matrix.org", file: .init(filename: "IMG_1.jpg", fileSize: 1024, mimeType: "image/jpeg"))
    
    @Test
    func localEchoIsMatchedByItsFile() {
        let store = PendingMediaBatchStore()
        let batch = MediaBatch(id: "b1", index: 0, count: 2)
        store.register(batch, for: key)
        
        #expect(store.batch(forItemIDs: ["unique-1", "txn-1"], key: key) == batch)
        #expect(store.batch(forItemIDs: ["unique-2", "txn-2"], key: otherFileKey) == nil)
    }
    
    @Test
    func samePhotoInTwoBatchesKeepsEachEchoOnItsOwn() {
        let store = PendingMediaBatchStore()
        let first = MediaBatch(id: "b1", index: 0, count: 2)
        let second = MediaBatch(id: "b2", index: 1, count: 2)
        store.register(first, for: key)
        store.register(second, for: key)
        
        #expect(store.batch(forItemIDs: ["unique-a", "txn-a"], key: key) == first)
        #expect(store.batch(forItemIDs: ["unique-b", "txn-b"], key: key) == second)
        #expect(store.batch(forItemIDs: ["unique-b", "$event-b"], key: key) == second)
        #expect(store.batch(forItemIDs: ["unique-a", "$event-a"], key: key) == first)
    }
    
    @Test
    func completedEntryIsForgotten() {
        let store = PendingMediaBatchStore()
        store.register(MediaBatch(id: "b1", index: 0, count: 2), for: key)
        _ = store.batch(forItemIDs: ["unique-1", "txn-1"], key: key)
        
        store.complete(itemIDs: ["unique-1", "$event-1"])
        
        #expect(store.batch(forItemIDs: ["unique-1", "$event-1"], key: key) == nil)
    }
    
    @Test
    func entriesExpireAfterADay() {
        let clock = Clock()
        let store = PendingMediaBatchStore { clock.now }
        store.register(MediaBatch(id: "b1", index: 0, count: 2), for: key)
        
        clock.advance(by: 24 * 60 * 60 + 1)
        
        #expect(store.batch(forItemIDs: ["unique-1", "txn-1"], key: key) == nil)
    }
    
    @Test
    func failedEnqueueLeavesOnlyTheRetrysEntry() async {
        let store = PendingMediaBatchStore()
        let timelineProxy = TimelineProxyMock(.init(timelineItemProvider: idleTimelineItemProvider))
        let controller = makeController(timelineProxy: timelineProxy, pendingMediaBatches: store)
        let batch = MediaBatch(id: "b1", index: 1, count: 3)
        
        timelineProxy.sendImageUrlThumbnailURLImageInfoCaptionExtraContentJSONRequestHandleReturnValue = .failure(.sdkError(EnqueueError()))
        _ = await sendImage(batch, with: controller)
        timelineProxy.sendImageUrlThumbnailURLImageInfoCaptionExtraContentJSONRequestHandleReturnValue = .success(())
        _ = await sendImage(batch, with: controller)
        
        #expect(store.batch(forItemIDs: ["unique-1", "txn-1"], key: key) == batch)
        #expect(store.batch(forItemIDs: ["unique-2", "txn-2"], key: key) == nil, "The failed attempt's entry would mark a later send of this file.")
    }
    
    @Test
    func unregisterKeepsAnEntryAnEchoHasBound() {
        let store = PendingMediaBatchStore()
        let batch = MediaBatch(id: "b1", index: 0, count: 2)
        store.register(batch, for: key)
        _ = store.batch(forItemIDs: ["unique-1", "txn-1"], key: key)
        
        store.unregister(batch, for: key)
        
        #expect(store.batch(forItemIDs: ["unique-1", "$event-1"], key: key) == batch)
    }
    
    private var otherFileKey: PendingMediaBatchStore.Key {
        .init(roomID: key.roomID, file: .init(filename: "IMG_2.jpg", fileSize: key.file.fileSize, mimeType: key.file.mimeType))
    }
    
    private var idleTimelineItemProvider: TimelineItemProviderMock {
        let provider = TimelineItemProviderMock()
        provider.kind = .live
        provider.paginationState = .init(backward: .idle, forward: .endReached)
        provider.membershipChangePublisher = PassthroughSubject().eraseToAnyPublisher()
        provider.updatePublisher = PassthroughSubject().eraseToAnyPublisher()
        return provider
    }
    
    private func makeController(timelineProxy: TimelineProxyMock, pendingMediaBatches: PendingMediaBatchStore) -> TimelineController {
        TimelineController(roomProxy: JoinedRoomProxyMock(.init(id: key.roomID)),
                           timelineProxy: timelineProxy,
                           initialFocussedEventID: nil,
                           timelineItemFactory: RoomTimelineItemFactory(userID: "@alice:matrix.org",
                                                                        attributedStringBuilder: AttributedStringBuilder(mentionBuilder: MentionBuilder()),
                                                                        stateEventStringBuilder: RoomStateEventStringBuilder(userID: "@alice:matrix.org")),
                           mediaProvider: MediaProviderMock(.init()),
                           userSettings: .mock(),
                           pendingMediaBatches: pendingMediaBatches)
    }
    
    private func sendImage(_ batch: MediaBatch, with controller: TimelineController) async -> Result<Void, TimelineControllerError> {
        await controller.sendImage(url: URL(filePath: "/tmp/\(key.file.filename)"),
                                   thumbnailURL: URL(filePath: "/tmp/thumbnail.jpg"),
                                   imageInfo: ImageInfo(height: nil, width: nil, mimetype: key.file.mimeType, size: key.file.fileSize.map(UInt64.init),
                                                        thumbnailInfo: nil, thumbnailSource: nil, blurhash: nil, isAnimated: nil),
                                   caption: nil,
                                   mediaBatch: batch) { _ in }
    }
}

private struct EnqueueError: Error { }

private final nonisolated class Clock: Sendable {
    private let date = Mutex(Date.now)
    
    var now: Date {
        date.withLock { $0 }
    }
    
    func advance(by interval: TimeInterval) {
        date.withLock { $0 = $0.addingTimeInterval(interval) }
    }
}
