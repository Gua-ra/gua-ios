//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import Synchronization

final nonisolated class MediaBatchCache: Sendable {
    private struct State {
        var batchesByEventID: [String: MediaBatch?] = [:]
        var stackIDsByMemberID: [TimelineItemIdentifier.UniqueID: TimelineItemIdentifier.UniqueID] = [:]
    }
    
    private let state = Mutex(State())
    
    func batch(forEventID eventID: String, parse: () -> MediaBatch?) -> MediaBatch? {
        if let cached = state.withLock({ $0.batchesByEventID[eventID] }) {
            return cached
        }
        
        let batch = parse()
        state.withLock { $0.batchesByEventID[eventID] = batch }
        return batch
    }
    
    func knownBatch(forEventID eventID: String) -> MediaBatch? {
        state.withLock { $0.batchesByEventID[eventID] ?? nil }
    }
    
    /// Kept while any member stays in the stack. `takenIDs` are this pass's IDs, as a repeated ID crashes the timeline table.
    func stackID(forMemberIDs memberIDs: [TimelineItemIdentifier.UniqueID],
                 excluding takenIDs: Set<TimelineItemIdentifier.UniqueID>) -> TimelineItemIdentifier.UniqueID {
        state.withLock { state in
            let knownID = memberIDs.compactMap { state.stackIDsByMemberID[$0] }.first { !takenIDs.contains($0) }
            let stackID = knownID ?? Self.newStackID(firstMemberID: memberIDs[0], excluding: takenIDs)
            for memberID in memberIDs {
                state.stackIDsByMemberID[memberID] = stackID
            }
            return stackID
        }
    }
    
    /// Unique IDs only hold within one SDK timeline, so stacks start over when the timeline is replaced.
    func resetStackIDs() {
        state.withLock { $0.stackIDsByMemberID.removeAll() }
    }
    
    private static func newStackID(firstMemberID: TimelineItemIdentifier.UniqueID,
                                   excluding takenIDs: Set<TimelineItemIdentifier.UniqueID>) -> TimelineItemIdentifier.UniqueID {
        let stackID = TimelineItemIdentifier.UniqueID("\(firstMemberID.value)_stack")
        return takenIDs.contains(stackID) ? TimelineItemIdentifier.UniqueID("\(stackID.value)_\(UUID().uuidString)") : stackID
    }
}

nonisolated struct MediaBatchSources: Sendable {
    let cache: MediaBatchCache
    let pendingBatches: PendingMediaBatchStore
    let roomID: String
    
    func attachingBatch(to item: RoomTimelineItemProtocol, from proxy: EventTimelineItemProxy) -> RoomTimelineItemProtocol {
        guard let member = MediaStackRoomTimelineItem.Member(item) else { return item }
        let batch = batch(of: proxy, key: .init(roomID: roomID, file: member.file))
        
        switch member {
        case .image(var image):
            image.mediaBatch = batch
            return image
        case .video(var video):
            video.mediaBatch = batch
            return video
        }
    }
    
    private func batch(of proxy: EventTimelineItemProxy, key: PendingMediaBatchStore.Key) -> MediaBatch? {
        let itemIDs = proxy.id.allIDs
        
        guard !proxy.isLocalEcho, let eventID = proxy.id.eventID else {
            return pendingBatches.batch(forItemIDs: itemIDs, key: key)
        }
        
        let batch = cache.batch(forEventID: eventID) { proxy.mediaBatch }
        if batch != nil, proxy.isOwn {
            pendingBatches.complete(itemIDs: itemIDs)
        }
        return batch
    }
}

private nonisolated extension TimelineItemIdentifier {
    /// The unique ID along with the transaction or event ID, as a local echo keeps the former and swaps the latter once sent.
    var allIDs: Set<String> {
        switch self {
        case .event(let uniqueID, .eventID(let id)), .event(let uniqueID, .transactionID(let id)): [uniqueID.value, id]
        case .virtual(let uniqueID): [uniqueID.value]
        }
    }
}
