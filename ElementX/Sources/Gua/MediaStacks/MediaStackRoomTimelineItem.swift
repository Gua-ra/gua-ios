//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import UniformTypeIdentifiers

nonisolated struct MediaStackRoomTimelineItem: EventBasedMessageTimelineItemProtocol, Equatable, Identifiable {
    enum Member: Equatable {
        case image(ImageRoomTimelineItem)
        case video(VideoRoomTimelineItem)
        
        var item: EventBasedMessageTimelineItemProtocol {
            switch self {
            case .image(let item): item
            case .video(let item): item
            }
        }
        
        var id: TimelineItemIdentifier {
            item.id
        }
        
        var isVideo: Bool {
            if case .video = self {
                true
            } else {
                false
            }
        }
        
        var mediaBatch: MediaBatch? {
            switch self {
            case .image(let item): item.mediaBatch
            case .video(let item): item.mediaBatch
            }
        }
        
        var uploadProgress: Double? {
            switch self {
            case .image(let item): item.uploadProgress
            case .video(let item): item.uploadProgress
            }
        }
        
        var mediaSource: MediaSourceProxy {
            switch self {
            case .image(let item): item.content.imageInfo.source
            case .video(let item): item.content.videoInfo.source
            }
        }
        
        var thumbnailSource: MediaSourceProxy? {
            switch self {
            case .image(let item): item.content.thumbnailInfo?.source
            case .video(let item): item.content.thumbnailInfo?.source
            }
        }
        
        var file: PendingMediaBatchStore.File {
            switch self {
            case .image(let item): .init(filename: item.content.filename, fileSize: item.content.imageInfo.fileSize, mimeType: item.content.imageInfo.mimeType)
            case .video(let item): .init(filename: item.content.filename, fileSize: item.content.videoInfo.fileSize, mimeType: item.content.videoInfo.mimeType)
            }
        }
        
        var blurhash: String? {
            switch self {
            case .image(let item): item.content.blurhash
            case .video(let item): item.content.blurhash
            }
        }
        
        var duration: TimeInterval? {
            guard case let .video(item) = self else { return nil }
            return item.content.videoInfo.duration
        }
        
        init?(_ item: RoomTimelineItemProtocol) {
            switch item {
            case let item as ImageRoomTimelineItem: self = .image(item)
            case let item as VideoRoomTimelineItem: self = .video(item)
            default: return nil
            }
        }
    }
    
    enum Kind {
        case photos
        case videos
        case items
    }
    
    let id: TimelineItemIdentifier
    /// Ordered by their index in the batch, never fewer than two.
    let members: [Member]
    /// The member last in timeline order that the server has, which read receipts go to.
    let newestEventID: String?
    let timestamp: Date
    let properties: RoomTimelineItemProperties
    
    init(stackID: TimelineItemIdentifier.UniqueID, members: [Member], newestEventID: String?) {
        let first = members[0].item
        self.members = members
        self.newestEventID = newestEventID
        id = first.id.replacingUniqueID(with: stackID)
        timestamp = members.reduce(first.timestamp) { max($0, $1.item.timestamp) }
        
        var properties = first.properties
        properties.deliveryStatus = Self.deliveryStatus(of: members.map(\.item.properties.deliveryStatus))
        properties.orderedReadReceipts = Self.readReceipts(of: members)
        self.properties = properties
    }
    
    var first: Member {
        members[0]
    }
    
    var kind: Kind {
        if members.allSatisfy(\.isVideo) {
            .videos
        } else if members.contains(where: \.isVideo) {
            .items
        } else {
            .photos
        }
    }
    
    var isOutgoing: Bool {
        first.item.isOutgoing
    }
    
    var isEditable: Bool {
        false
    }
    
    var canBeRepliedTo: Bool {
        first.item.canBeRepliedTo
    }
    
    var sender: TimelineItemSender {
        first.item.sender
    }
    
    var body: String {
        first.item.body
    }
    
    var contentType: EventBasedMessageTimelineItemContentType {
        first.item.contentType
    }
    
    var isFirstMemberReactable: Bool {
        first.item.isReactable
    }
    
    var firstFailedMember: Member? {
        members.first { $0.item.hasFailedToSend }
    }
    
    func memberIndex(ofEventID eventID: String) -> Int? {
        members.firstIndex { $0.id.eventID == eventID }
    }
    
    private static func deliveryStatus(of statuses: [TimelineItemDeliveryStatus?]) -> TimelineItemDeliveryStatus? {
        if let failed = statuses.first(where: { $0?.isSendingFailed == true }) {
            failed
        } else if statuses.contains(.sending) {
            .sending
        } else if statuses.contains(.sent) {
            .sent
        } else {
            nil
        }
    }
    
    private static func readReceipts(of members: [Member]) -> [ReadReceipt] {
        var userIDs = Set<String>()
        return members.reversed()
            .flatMap(\.item.properties.orderedReadReceipts)
            .filter { userIDs.insert($0.userID).inserted }
    }
}

nonisolated extension TimelineItemIdentifier {
    func replacingUniqueID(with uniqueID: UniqueID) -> TimelineItemIdentifier {
        switch self {
        case .event(_, let eventOrTransactionID): .event(uniqueID: uniqueID, eventOrTransactionID: eventOrTransactionID)
        case .virtual: .virtual(uniqueID: uniqueID)
        }
    }
}

nonisolated extension RoomTimelineItemProtocol {
    func represents(eventID: String) -> Bool {
        id.eventID == eventID || (self as? MediaStackRoomTimelineItem)?.memberIndex(ofEventID: eventID) != nil
    }
}

nonisolated extension MediaStackRoomTimelineItem {
    static func mock(id: String = "stack", members: [Member]) -> MediaStackRoomTimelineItem {
        .init(stackID: .init(id), members: members, newestEventID: members.last?.id.eventID)
    }
}

nonisolated extension MediaStackRoomTimelineItem.Member {
    static func mockImage(index: Int,
                          count: Int,
                          batchID: String = "batch",
                          isOutgoing: Bool = false,
                          caption: String? = nil,
                          properties: RoomTimelineItemProperties = .init(),
                          uploadProgress: Double? = nil) -> Self {
        .image(ImageRoomTimelineItem(id: .mock(batchID: batchID, index: index),
                                     timestamp: .mock,
                                     isOutgoing: isOutgoing,
                                     isEditable: isOutgoing,
                                     canBeRepliedTo: true,
                                     sender: .mock(isOutgoing: isOutgoing),
                                     content: .init(filename: "IMG_\(index).jpg",
                                                    caption: caption,
                                                    imageInfo: .mockImage,
                                                    thumbnailInfo: .mockThumbnail,
                                                    blurhash: "L%KUc%kqS$RP?Ks,WEf8OlrqaekW",
                                                    contentType: .jpeg),
                                     properties: properties,
                                     mediaBatch: .init(id: batchID, index: index, count: count),
                                     uploadProgress: uploadProgress))
    }
    
    static func mockVideo(index: Int,
                          count: Int,
                          batchID: String = "batch",
                          isOutgoing: Bool = false,
                          properties: RoomTimelineItemProperties = .init()) -> Self {
        .video(VideoRoomTimelineItem(id: .mock(batchID: batchID, index: index),
                                     timestamp: .mock,
                                     isOutgoing: isOutgoing,
                                     isEditable: isOutgoing,
                                     canBeRepliedTo: true,
                                     sender: .mock(isOutgoing: isOutgoing),
                                     content: .init(filename: "IMG_\(index).mov",
                                                    videoInfo: .mockVideo(duration: 42),
                                                    thumbnailInfo: .mockVideoThumbnail,
                                                    blurhash: "L%KUc%kqS$RP?Ks,WEf8OlrqaekW",
                                                    contentType: .mpeg4Movie),
                                     properties: properties,
                                     mediaBatch: .init(id: batchID, index: index, count: count)))
    }
}

private nonisolated extension TimelineItemIdentifier {
    static func mock(batchID: String, index: Int) -> TimelineItemIdentifier {
        .event(uniqueID: .init("\(batchID)-\(index)"), eventOrTransactionID: .eventID("$\(batchID)-\(index)"))
    }
}

private nonisolated extension TimelineItemSender {
    static func mock(isOutgoing: Bool) -> TimelineItemSender {
        isOutgoing ? .init(id: "@me:matrix.org", displayName: "Me") : .init(id: "@alice:matrix.org", displayName: "Alice")
    }
}
