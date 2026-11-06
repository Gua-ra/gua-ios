//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import Synchronization

final nonisolated class PendingMediaBatchStore: Sendable {
    struct File: Hashable {
        let filename: String
        let fileSize: UInt?
        let mimeType: String?
    }
    
    struct Key: Hashable {
        let roomID: String
        let file: File
    }
    
    private struct Entry {
        let key: Key
        let batch: MediaBatch
        let date: Date
        var itemIDs: Set<String> = []
    }
    
    private static let lifetime: TimeInterval = 24 * 60 * 60
    
    private let entries = Mutex<[Entry]>([])
    private let now: @Sendable () -> Date
    
    init(now: @escaping @Sendable () -> Date = { .now }) {
        self.now = now
    }
    
    func register(_ batch: MediaBatch, for key: Key) {
        let date = now()
        entries.withLock { $0.append(Entry(key: key, batch: batch, date: date)) }
    }
    
    /// Drops the newest entry for this item that no echo has bound to, so a failed enqueue leaves nothing for a later send of the same file.
    func unregister(_ batch: MediaBatch, for key: Key) {
        entries.withLock { entries in
            guard let index = entries.lastIndex(where: { $0.itemIDs.isEmpty && $0.key == key && $0.batch == batch }) else { return }
            entries.remove(at: index)
        }
    }
    
    /// Binds the echo to the oldest free entry for its file the first time it is seen, then finds it by any of its IDs.
    func batch(forItemIDs itemIDs: Set<String>, key: Key) -> MediaBatch? {
        let expiry = now().addingTimeInterval(-Self.lifetime)
        return entries.withLock { entries in
            entries.removeAll { $0.date < expiry }
            
            let index = entries.firstIndex { !$0.itemIDs.isDisjoint(with: itemIDs) }
                ?? entries.firstIndex { $0.itemIDs.isEmpty && $0.key == key }
            guard let index else { return nil }
            
            entries[index].itemIDs.formUnion(itemIDs)
            return entries[index].batch
        }
    }
    
    func complete(itemIDs: Set<String>) {
        entries.withLock { $0.removeAll { !$0.itemIDs.isDisjoint(with: itemIDs) } }
    }
}

nonisolated struct MediaBatchForwarding {
    let files: [PendingMediaBatchStore.File]
    let pendingBatches: PendingMediaBatchStore
    
    func makeBatches() -> [MediaBatch?] {
        MediaBatch.makeBatches(count: files.count)
    }
    
    /// Registers the members from `index` on before they are enqueued, so that the chat's local echoes stack before the server copies arrive.
    func register(_ batches: [MediaBatch?], from index: Int, forRoomID roomID: String) {
        for (batch, file) in zip(batches, files).dropFirst(index) {
            if let batch {
                pendingBatches.register(batch, for: .init(roomID: roomID, file: file))
            }
        }
    }
    
    /// Drops the entries of the members from `index` on, which a forward that stopped there never enqueued.
    func unregister(_ batches: [MediaBatch?], from index: Int, forRoomID roomID: String) {
        for (batch, file) in zip(batches, files).dropFirst(index) {
            if let batch {
                pendingBatches.unregister(batch, for: .init(roomID: roomID, file: file))
            }
        }
    }
}
