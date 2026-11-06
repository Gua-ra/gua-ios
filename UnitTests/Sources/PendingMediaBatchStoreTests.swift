//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Synchronization
import Testing

struct PendingMediaBatchStoreTests {
    private let key = PendingMediaBatchStore.Key(roomID: "!room:matrix.org", filename: "IMG_1.jpg", fileSize: 1024, mimeType: "image/jpeg")
    
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
    
    private var otherFileKey: PendingMediaBatchStore.Key {
        .init(roomID: key.roomID, filename: "IMG_2.jpg", fileSize: key.fileSize, mimeType: key.mimeType)
    }
}

private final nonisolated class Clock: Sendable {
    private let date = Mutex(Date.now)
    
    var now: Date {
        date.withLock { $0 }
    }
    
    func advance(by interval: TimeInterval) {
        date.withLock { $0 = $0.addingTimeInterval(interval) }
    }
}
