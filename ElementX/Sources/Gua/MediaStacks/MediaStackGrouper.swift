//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Foundation

nonisolated enum MediaStackGrouper {
    /// Items are ordered oldest first.
    static func group(_ items: [RoomTimelineItemProtocol], cache: MediaBatchCache) -> [RoomTimelineItemProtocol] {
        var groupedItems = [RoomTimelineItemProtocol]()
        var stackIDs = Set<TimelineItemIdentifier.UniqueID>()
        var threadHeadIndex: Int?
        var index = items.startIndex
        
        while index < items.endIndex {
            guard index != threadHeadIndex, let candidate = Candidate(items[index], cache: cache) else {
                groupedItems.append(items[index])
                index += 1
                continue
            }
            
            let run = run(startingWith: candidate, at: index, in: items, cache: cache)
            groupedItems += render(items[index...run.lastCandidateIndex], cache: cache, stackIDs: &stackIDs)
            threadHeadIndex = run.threadHeadIndex
            index = run.lastCandidateIndex + 1
        }
        
        return groupedItems
    }
    
    private static func run(startingWith first: Candidate,
                            at startIndex: Int,
                            in items: [RoomTimelineItemProtocol],
                            cache: MediaBatchCache) -> Run {
        var batchIndexes: Set<Int> = [first.batch.index]
        var lastCandidateIndex = startIndex
        
        for index in (startIndex + 1)..<items.endIndex {
            let item = items[index]
            let candidate = Candidate(item, cache: cache)
            
            if let candidate, candidate.continues(first) {
                guard batchIndexes.insert(candidate.batch.index).inserted else { break }
                if candidate.headsThread {
                    return Run(lastCandidateIndex: lastCandidateIndex, threadHeadIndex: index)
                }
                lastCandidateIndex = index
            } else if candidate == nil, item is ReadMarkerRoomTimelineItem || (item as? RedactedRoomTimelineItem)?.sender.id == first.sender {
                continue
            } else {
                break
            }
        }
        
        return Run(lastCandidateIndex: lastCandidateIndex)
    }
    
    private static func render(_ run: ArraySlice<RoomTimelineItemProtocol>,
                               cache: MediaBatchCache,
                               stackIDs: inout Set<TimelineItemIdentifier.UniqueID>) -> [RoomTimelineItemProtocol] {
        let members = run.compactMap { item -> (batch: MediaBatch, member: MediaStackRoomTimelineItem.Member)? in
            guard let member = MediaStackRoomTimelineItem.Member(item), let batch = member.mediaBatch else { return nil }
            return (batch, member)
        }
        
        guard members.count > 1 else {
            // With no member left, the first removal stands for the whole run.
            let shownID = members.first?.member.id ?? run[run.startIndex].id
            return run.filter { $0 is ReadMarkerRoomTimelineItem || $0.id == shownID }
        }
        
        let sortedMembers = members.sorted { $0.batch.index < $1.batch.index }.map(\.member)
        let stackID = cache.stackID(forMemberIDs: sortedMembers.map(\.id.uniqueID), excluding: stackIDs)
        stackIDs.insert(stackID)
        
        let stack = MediaStackRoomTimelineItem(stackID: stackID,
                                               members: sortedMembers,
                                               newestEventID: members.last { $0.member.id.eventID != nil }?.member.id.eventID)
        return run.filter { $0 is ReadMarkerRoomTimelineItem } + [stack]
    }
}

private nonisolated struct Run {
    let lastCandidateIndex: Int
    /// A later member that heads a thread ends the run and renders on its own, so the thread stays reachable.
    var threadHeadIndex: Int?
}

private nonisolated struct Candidate {
    let batch: MediaBatch
    let sender: String
    let headsThread: Bool
    
    func continues(_ first: Candidate) -> Bool {
        batch.id == first.batch.id && sender == first.sender
    }
}

private nonisolated extension Candidate {
    init?(_ item: RoomTimelineItemProtocol, cache: MediaBatchCache) {
        if let member = MediaStackRoomTimelineItem.Member(item) {
            guard let batch = member.mediaBatch else { return nil }
            self.init(batch: batch, sender: member.item.sender.id, headsThread: member.item.properties.threadSummary != nil)
        } else if let removed = item as? RedactedRoomTimelineItem, let eventID = removed.id.eventID, let batch = cache.knownBatch(forEventID: eventID) {
            self.init(batch: batch, sender: removed.sender.id, headsThread: removed.properties.threadSummary != nil)
        } else {
            return nil
        }
    }
}
