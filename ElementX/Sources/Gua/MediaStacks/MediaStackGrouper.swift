//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// Turns runs of photos and videos sent together into stacks. Items are ordered oldest first.
nonisolated enum MediaStackGrouper {
    static func group(_ items: [RoomTimelineItemProtocol], cache: MediaBatchCache) -> [RoomTimelineItemProtocol] {
        var groupedItems = [RoomTimelineItemProtocol]()
        var stackIDs = Set<TimelineItemIdentifier.UniqueID>()
        var index = items.startIndex
        
        while index < items.endIndex {
            guard let candidate = Candidate(items[index], cache: cache) else {
                groupedItems.append(items[index])
                index += 1
                continue
            }
            
            let runEnd = lastIndexOfRun(startingWith: candidate, at: index, in: items, cache: cache)
            groupedItems += render(items[index...runEnd], cache: cache, stackIDs: &stackIDs)
            index = runEnd + 1
            
            // A later member that heads a thread ends the run, and renders on its own so the thread stays reachable.
            if index < items.endIndex, let next = Candidate(items[index], cache: cache), next.continues(candidate), next.headsThread {
                groupedItems.append(items[index])
                index += 1
            }
        }
        
        return groupedItems
    }
    
    private static func lastIndexOfRun(startingWith first: Candidate,
                                       at startIndex: Int,
                                       in items: [RoomTimelineItemProtocol],
                                       cache: MediaBatchCache) -> Int {
        var batchIndexes: Set<Int> = [first.batch.index]
        var lastCandidateIndex = startIndex
        
        for index in (startIndex + 1)..<items.endIndex {
            let item = items[index]
            
            if let candidate = Candidate(item, cache: cache), candidate.continues(first) {
                guard !candidate.headsThread, batchIndexes.insert(candidate.batch.index).inserted else { break }
                lastCandidateIndex = index
            } else if item is ReadMarkerRoomTimelineItem {
                continue
            } else if let removed = item as? RedactedRoomTimelineItem, removed.sender.id == first.sender,
                      Candidate(item, cache: cache) == nil {
                continue
            } else {
                break
            }
        }
        
        return lastCandidateIndex
    }
    
    private static func render(_ run: ArraySlice<RoomTimelineItemProtocol>,
                               cache: MediaBatchCache,
                               stackIDs: inout Set<TimelineItemIdentifier.UniqueID>) -> [RoomTimelineItemProtocol] {
        let readMarkers = run.filter { $0 is ReadMarkerRoomTimelineItem }
        let members = run.compactMap(member(of:))
            .sorted { $0.batch.index < $1.batch.index }
            .map(\.member)
        
        switch members.count {
        case 0:
            // Only removed members are left, so the first removal stands for the whole stack.
            return readMarkers + [run[run.startIndex]]
        case 1:
            return readMarkers + [members[0].item]
        default:
            let stackID = cache.stackID(forMemberIDs: members.map(\.id.uniqueID), excluding: stackIDs)
            stackIDs.insert(stackID)
            return readMarkers + [MediaStackRoomTimelineItem(stackID: stackID, members: members)]
        }
    }
    
    /// Every image and video in a run carries a marker.
    private static func member(of item: RoomTimelineItemProtocol) -> (batch: MediaBatch, member: MediaStackRoomTimelineItem.Member)? {
        switch item {
        case let item as ImageRoomTimelineItem: item.mediaBatch.map { ($0, .image(item)) }
        case let item as VideoRoomTimelineItem: item.mediaBatch.map { ($0, .video(item)) }
        default: nil
        }
    }
}

private nonisolated struct Candidate {
    let batch: MediaBatch
    let sender: String
    let headsThread: Bool
    
    init?(_ item: RoomTimelineItemProtocol, cache: MediaBatchCache) {
        switch item {
        case let item as ImageRoomTimelineItem:
            guard let batch = item.mediaBatch else { return nil }
            self.init(batch: batch, sender: item.sender.id, headsThread: item.properties.threadSummary != nil)
        case let item as VideoRoomTimelineItem:
            guard let batch = item.mediaBatch else { return nil }
            self.init(batch: batch, sender: item.sender.id, headsThread: item.properties.threadSummary != nil)
        case let item as RedactedRoomTimelineItem:
            guard let eventID = item.id.eventID, let batch = cache.knownBatch(forEventID: eventID) else { return nil }
            self.init(batch: batch, sender: item.sender.id, headsThread: false)
        default:
            return nil
        }
    }
    
    private init(batch: MediaBatch, sender: String, headsThread: Bool) {
        self.batch = batch
        self.sender = sender
        self.headsThread = headsThread
    }
    
    func continues(_ first: Candidate) -> Bool {
        batch.id == first.batch.id && sender == first.sender
    }
}
