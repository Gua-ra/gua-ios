//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import Synchronization

/// Remembers the batches sent in this session, because a local echo has no event JSON to read the marker from.
final nonisolated class PendingMediaBatchStore: Sendable {
    struct Key: Hashable {
        let roomID: String
        let filename: String
        let fileSize: UInt?
        let mimeType: String?
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
