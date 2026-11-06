//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

struct MediaStackGrouperTests {
    @Test
    func fixtureGrouping() throws {
        for fixture in try MediaBatchFixtures.load().grouping {
            let name = try #require(fixture["name"] as? String)
            let fixtureItems = try #require(fixture["items"] as? [[String: Any]])
            let expected = try #require(fixture["expected"] as? [[String]])
            
            let cache = MediaBatchCache()
            let items = fixtureItems.map { Self.timelineItem(from: $0, seeding: cache) }
            let grouped = MediaStackGrouper.group(items, cache: cache)
            
            #expect(Self.describe(grouped, input: fixtureItems) == expected, Comment(rawValue: name))
        }
    }
    
    @Test
    func stackIDSurvivesOlderMembersPaginatingIn() throws {
        let cache = MediaBatchCache()
        let newerMembers = [image("$2", batch: .init(id: "b", index: 1, count: 3)), image("$3", batch: .init(id: "b", index: 2, count: 3))]
        let firstPass = try #require(MediaStackGrouper.group(newerMembers, cache: cache).first as? MediaStackRoomTimelineItem)
        
        let secondPass = try #require(MediaStackGrouper.group([image("$1", batch: .init(id: "b", index: 0, count: 3))] + newerMembers, cache: cache).first as? MediaStackRoomTimelineItem)
        
        #expect(secondPass.members.map(\.id.eventID) == ["$1", "$2", "$3"])
        #expect(secondPass.id.uniqueID == firstPass.id.uniqueID)
        #expect(secondPass.id.eventID == "$1", "The stack acts on its first member.")
    }
    
    @Test
    func stacksSplitByAMessageGetDistinctIDs() {
        let cache = MediaBatchCache()
        let members = (0..<4).map { image("$\($0)", batch: .init(id: "b", index: $0, count: 4)) }
        _ = MediaStackGrouper.group(members, cache: cache)
        
        let split = MediaStackGrouper.group(Array(members[0..<2]) + [text("$t")] + Array(members[2..<4]), cache: cache)
        let stackIDs = split.compactMap { ($0 as? MediaStackRoomTimelineItem)?.id.uniqueID }
        
        #expect(stackIDs.count == 2)
        #expect(Set(stackIDs).count == 2)
        #expect(Set(split.map(\.id.uniqueID)).count == split.count)
    }
    
    @Test
    func stackCombinesItsMembersState() throws {
        let failure = TimelineItemDeliveryStatus.sendingFailed(.unknown(reason: nil))
        let members = [image("$1", batch: .init(id: "b", index: 0, count: 3), deliveryStatus: .sending, receipts: ["@bob:matrix.org"]),
                       image("$2", batch: .init(id: "b", index: 1, count: 3), deliveryStatus: failure),
                       image("$3", batch: .init(id: "b", index: 2, count: 3), receipts: ["@carol:matrix.org", "@bob:matrix.org"])]
        
        let stack = try #require(MediaStackGrouper.group(members, cache: MediaBatchCache()).first as? MediaStackRoomTimelineItem)
        
        #expect(stack.properties.deliveryStatus == failure)
        #expect(stack.firstFailedMember?.id.eventID == "$2")
        #expect(stack.properties.orderedReadReceipts.map(\.userID) == ["@carol:matrix.org", "@bob:matrix.org"])
        #expect(stack.newestEventID == "$3")
    }
    
    @Test
    func readReceiptsGoToTheNewestSentMember() throws {
        let localEcho = ImageRoomTimelineItem(id: .event(uniqueID: .init("echo"), eventOrTransactionID: .transactionID("txn")),
                                              timestamp: .mock, isOutgoing: true, isEditable: true, canBeRepliedTo: true,
                                              sender: .init(id: "@me:matrix.org"), content: .init(filename: "echo.jpg", imageInfo: .mockImage, thumbnailInfo: nil),
                                              mediaBatch: .init(id: "b", index: 0, count: 3))
        let members: [RoomTimelineItemProtocol] = [image("$2", batch: .init(id: "b", index: 2, count: 3)),
                                                   image("$1", batch: .init(id: "b", index: 1, count: 3)),
                                                   localEcho]
        
        let stack = try #require(MediaStackGrouper.group(members, cache: MediaBatchCache()).first as? MediaStackRoomTimelineItem)
        
        #expect(stack.members.map(\.id.uniqueID.value) == ["echo", "$1", "$2"])
        #expect(stack.newestEventID == "$1", "The newest member in timeline order that has been sent.")
    }
    
    private static func timelineItem(from fixture: [String: Any], seeding cache: MediaBatchCache) -> RoomTimelineItemProtocol {
        let id = fixture["id"] as? String ?? ""
        let sender = fixture["sender"] as? String ?? ""
        let batch = (fixture["batch"] as? [Any]).flatMap(mediaBatch)
        let threadSummary: TimelineItemThreadSummary? = fixture["threadRoot"] as? Bool == true ? .notLoaded : nil
        
        switch fixture["kind"] as? String {
        case "image":
            return ImageRoomTimelineItem(id: eventID(id), timestamp: .mock, isOutgoing: false, isEditable: false, canBeRepliedTo: true,
                                         sender: .init(id: sender), content: .init(filename: "\(id).jpg", imageInfo: .mockImage, thumbnailInfo: nil),
                                         properties: .init(threadSummary: threadSummary), mediaBatch: batch)
        case "video":
            return VideoRoomTimelineItem(id: eventID(id), timestamp: .mock, isOutgoing: false, isEditable: false, canBeRepliedTo: true,
                                         sender: .init(id: sender), content: .init(filename: "\(id).mp4", videoInfo: .mockVideo, thumbnailInfo: nil),
                                         properties: .init(threadSummary: threadSummary), mediaBatch: batch)
        case "redacted":
            if let known = (fixture["known"] as? [Any]).flatMap(mediaBatch) {
                _ = cache.batch(forEventID: id) { known }
            }
            return RedactedRoomTimelineItem(id: eventID(id), body: "", timestamp: .mock, isOutgoing: false, isEditable: false,
                                            canBeRepliedTo: false, sender: .init(id: sender))
        case "utd":
            return EncryptedRoomTimelineItem(id: eventID(id), body: "", encryptionType: .unknown, timestamp: .mock, isOutgoing: false,
                                             isEditable: false, canBeRepliedTo: false, sender: .init(id: sender))
        case "day":
            return SeparatorRoomTimelineItem(id: .virtual(uniqueID: .init(id)), timestamp: .mock)
        case "readMarker":
            return ReadMarkerRoomTimelineItem(id: .virtual(uniqueID: .init(id)))
        default:
            return TextRoomTimelineItem(id: eventID(id), timestamp: .mock, isOutgoing: false, isEditable: false, canBeRepliedTo: true,
                                        sender: .init(id: sender), content: .init(body: id))
        }
    }
    
    /// Describes the grouped items in the fixtures' terms. A removed tile lists the hidden removals of its batch after its own.
    private static func describe(_ items: [RoomTimelineItemProtocol], input: [[String: Any]]) -> [[String]] {
        let shownIDs = Set(items.compactMap(\.id.eventID))
        
        return items.map { item in
            switch item {
            case let stack as MediaStackRoomTimelineItem:
                let kind = switch stack.kind {
                case .photos: "photos"
                case .videos: "videos"
                case .items: "items"
                }
                return ["stack", kind] + stack.members.compactMap(\.id.eventID)
            case is SeparatorRoomTimelineItem:
                return ["day"]
            case is ReadMarkerRoomTimelineItem:
                return ["readMarker"]
            case let removed as RedactedRoomTimelineItem:
                guard let known = input.first(where: { $0["id"] as? String == removed.id.eventID })?["known"] as? [Any],
                      let batchID = known.first as? String else {
                    return ["item", removed.id.eventID ?? ""]
                }
                let hiddenIDs = input.filter { ($0["known"] as? [Any])?.first as? String == batchID }
                    .compactMap { $0["id"] as? String }
                    .filter { $0 != removed.id.eventID && !shownIDs.contains($0) }
                return ["removed", removed.id.eventID ?? ""] + hiddenIDs
            default:
                return ["item", item.id.eventID ?? ""]
            }
        }
    }
    
    private static func mediaBatch(_ values: [Any]) -> MediaBatch? {
        guard values.count == 3, let id = values[0] as? String, let index = values[1] as? Int, let count = values[2] as? Int else { return nil }
        return MediaBatch(id: id, index: index, count: count)
    }
    
    private static func eventID(_ id: String) -> TimelineItemIdentifier {
        .event(uniqueID: .init(id), eventOrTransactionID: .eventID(id))
    }
    
    private func image(_ id: String,
                       batch: MediaBatch,
                       deliveryStatus: TimelineItemDeliveryStatus? = nil,
                       receipts: [String] = []) -> ImageRoomTimelineItem {
        ImageRoomTimelineItem(id: Self.eventID(id), timestamp: .mock, isOutgoing: true, isEditable: true, canBeRepliedTo: true,
                              sender: .init(id: "@me:matrix.org"), content: .init(filename: "\(id).jpg", imageInfo: .mockImage, thumbnailInfo: nil),
                              properties: .init(deliveryStatus: deliveryStatus,
                                                orderedReadReceipts: receipts.map { ReadReceipt(userID: $0, formattedTimestamp: nil) }),
                              mediaBatch: batch)
    }
    
    private func text(_ id: String) -> TextRoomTimelineItem {
        TextRoomTimelineItem(id: Self.eventID(id), timestamp: .mock, isOutgoing: true, isEditable: true, canBeRepliedTo: true,
                             sender: .init(id: "@me:matrix.org"), content: .init(body: id))
    }
}
