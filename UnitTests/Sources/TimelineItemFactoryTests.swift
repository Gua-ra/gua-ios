//
// Copyright 2025 Element Creations Ltd.
// Copyright 2024-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import MatrixRustSDK
import Testing

@MainActor
struct TimelineItemFactoryTests {
    @Test
    func callInvite() throws {
        let ownUserID = "@alice:matrix.org"
        let senderUserID = "@bob:matrix.org"
        
        let factory = RoomTimelineItemFactory(userID: ownUserID,
                                              attributedStringBuilder: AttributedStringBuilder(mentionBuilder: MentionBuilder()),
                                              stateEventStringBuilder: RoomStateEventStringBuilder(userID: ownUserID))
        
        let eventTimelineItem = EventTimelineItem.mockCallInvite(sender: senderUserID)
        
        let eventTimelineItemProxy = EventTimelineItemProxy(item: eventTimelineItem, uniqueID: .init("0"))
        
        let item = try #require(factory.buildTimelineItem(for: eventTimelineItemProxy, isDM: false) as? CallInviteRoomTimelineItem,
                                "Incorrect item type")
        
        #expect(item.isReactable == false)
        #expect(item.canBeRepliedTo == false)
        #expect(item.isEditable == false)
        #expect(item.sender == TimelineItemSender(id: senderUserID))
        #expect(item.properties.isEdited == false)
        #expect(item.properties.reactions == [])
        #expect(item.properties.deliveryStatus == nil)
    }
    
    @Test
    func animatedStickerKeepsItsAnimationFlag() throws {
        let info = ImageInfo(height: 128, width: 128, mimetype: "image/webp", size: 1000, thumbnailInfo: nil, thumbnailSource: nil, blurhash: nil, isAnimated: true)
        let content = try TimelineItemContent.msgLike(content: .init(kind: .sticker(body: "Dance", info: info, source: MediaSource.fromUrl(url: "mxc://gua.global/dance")),
                                                                     inReplyTo: nil,
                                                                     threadRoot: nil,
                                                                     threadSummary: nil))
        
        let item = try #require(buildItem(content: content) as? StickerRoomTimelineItem)
        
        #expect(item.imageInfo.isAnimated)
        #expect(item.imageInfo.size?.width == 128)
    }
    
    @Test
    func animatedImageKeepsItsAnimationFlag() throws {
        for isAnimated in [true, false, nil] {
            let info = ImageInfo(height: 280, width: 498, mimetype: "image/webp", size: 1000, thumbnailInfo: nil, thumbnailSource: nil, blurhash: nil, isAnimated: isAnimated)
            let image = try ImageMessageContent(filename: "Hello", caption: nil, formattedCaption: nil, source: MediaSource.fromUrl(url: "mxc://gua.global/hello"), info: info)
            let content = TimelineItemContent.msgLike(content: .init(kind: .message(content: .init(msgType: .image(content: image), body: "Hello", isEdited: false, mentions: nil)),
                                                                     inReplyTo: nil,
                                                                     threadRoot: nil,
                                                                     threadSummary: nil))
            
            let item = try #require(buildItem(content: content) as? ImageRoomTimelineItem)
            
            #expect(item.content.imageInfo.isAnimated == (isAnimated == true))
        }
    }
    
    private func buildItem(content: TimelineItemContent) -> RoomTimelineItemProtocol? {
        let factory = RoomTimelineItemFactory(userID: "@alice:matrix.org",
                                              attributedStringBuilder: AttributedStringBuilder(mentionBuilder: MentionBuilder()),
                                              stateEventStringBuilder: RoomStateEventStringBuilder(userID: "@alice:matrix.org"))
        let eventTimelineItem = EventTimelineItem(configuration: .init(sender: "@bob:matrix.org", content: content))
        return factory.buildTimelineItem(for: EventTimelineItemProxy(item: eventTimelineItem, uniqueID: .init("0")), isDM: false)
    }
}
