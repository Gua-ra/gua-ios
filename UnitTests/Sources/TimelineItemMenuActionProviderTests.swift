//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Testing

struct TimelineItemMenuActionProviderTests {
    @Test
    func liveLocationShareIsNotForwardable() throws {
        let item = makeLiveLocationItem(isLive: true)
        let actions = try #require(makeActions(for: item))
        
        let hasForward = actions.actions.contains(where: \.isForward)
        #expect(!hasForward)
    }
    
    @Test
    func endedLiveLocationShareIsNotForwardable() throws {
        let item = makeLiveLocationItem(isLive: false)
        let actions = try #require(makeActions(for: item))
        
        let hasForward = actions.actions.contains(where: \.isForward)
        #expect(!hasForward)
    }
    
    @Test
    func pollIsNotForwardable() throws {
        let item = PollRoomTimelineItem.mock(poll: .emptyDisclosed)
        let actions = try #require(makeActions(for: item))
        
        let hasForward = actions.actions.contains(where: \.isForward)
        #expect(!hasForward)
    }
    
    @Test
    func textMessageIsForwardable() throws {
        let item = TextRoomTimelineItem(id: .randomEvent,
                                        timestamp: .mock,
                                        isOutgoing: false,
                                        isEditable: false,
                                        canBeRepliedTo: true,
                                        sender: .init(id: "@alice:matrix.org"),
                                        content: .init(body: "Hello"))
        let actions = try #require(makeActions(for: item))
        
        let hasForward = actions.actions.contains(where: \.isForward)
        #expect(hasForward)
    }
    
    @Test
    func redactedMessageIsNotForwardable() throws {
        let item = RedactedRoomTimelineItem(id: .randomEvent,
                                            body: "Message removed",
                                            timestamp: .mock,
                                            isOutgoing: false,
                                            isEditable: false,
                                            canBeRepliedTo: false,
                                            sender: .init(id: "@alice:matrix.org"))
        let actions = try #require(makeActions(for: item))
        
        let hasForward = actions.actions.contains(where: \.isForward)
        #expect(!hasForward)
    }
    
    @Test
    func encryptedMessageIsNotForwardable() throws {
        let item = EncryptedRoomTimelineItem(id: .randomEvent,
                                             body: "",
                                             encryptionType: .unknown,
                                             timestamp: .mock,
                                             isOutgoing: false,
                                             isEditable: false,
                                             canBeRepliedTo: false,
                                             sender: .init(id: "@alice:matrix.org"))
        let actions = try #require(makeActions(for: item))
        
        let hasForward = actions.actions.contains(where: \.isForward)
        #expect(!hasForward)
    }
    
    @Test
    func localEchoIsNotForwardable() throws {
        let item = makeTextItem(id: .event(uniqueID: .init("local"), eventOrTransactionID: .transactionID("txn")))
        let actions = try #require(makeActions(for: item))
        
        let hasForward = actions.actions.contains(where: \.isForward)
        #expect(!hasForward)
    }
    
    @Test
    func stackOffersActionsForAllOfItsMembers() throws {
        let stack = MediaStackRoomTimelineItem.mock(members: [.mockImage(index: 0, count: 2, isOutgoing: true, caption: "Beach day"),
                                                              .mockVideo(index: 1, count: 2, isOutgoing: true)])
        let actions = try #require(makeActions(for: stack))
        
        #expect(actions.actions == [.reply(isThread: false), .replyInThread, .forward(itemID: stack.id), .saveMedia, .copyCaption, .copyPermalink, .viewSource])
        #expect(actions.secondaryActions == [.redact(isMedia: false)])
        #expect(!actions.reactions.isEmpty)
    }
    
    @Test
    func stackFromSomeoneElseCanBeReportedButNotRemoved() throws {
        let stack = MediaStackRoomTimelineItem.mock(members: (0..<2).map { .mockImage(index: $0, count: 2) })
        let actions = try #require(makeActions(for: stack))
        
        #expect(!actions.actions.contains(.copyCaption))
        #expect(actions.secondaryActions == [.report])
    }
    
    @Test
    func stackWithAnUnsentMemberCannotBeForwarded() throws {
        let unsent = ImageRoomTimelineItem(id: .event(uniqueID: .init("local"), eventOrTransactionID: .transactionID("txn")),
                                           timestamp: .mock, isOutgoing: true, isEditable: true, canBeRepliedTo: false,
                                           sender: .init(id: "@me:matrix.org"),
                                           content: .init(filename: "IMG_1.jpg", imageInfo: .mockImage, thumbnailInfo: nil),
                                           properties: .init(deliveryStatus: .sending),
                                           mediaBatch: .init(id: "batch", index: 1, count: 2))
        let stack = MediaStackRoomTimelineItem.mock(members: [.mockImage(index: 0, count: 2, isOutgoing: true), .image(unsent)])
        let actions = try #require(makeActions(for: stack))
        
        let hasForward = actions.actions.contains(where: \.isForward)
        #expect(!hasForward)
        #expect(actions.actions.contains(.saveMedia))
    }
    
    // MARK: - Helpers
    
    private func makeTextItem(id: TimelineItemIdentifier = .randomEvent) -> TextRoomTimelineItem {
        .init(id: id,
              timestamp: .mock,
              isOutgoing: false,
              isEditable: false,
              canBeRepliedTo: true,
              sender: .init(id: "@alice:matrix.org"),
              content: .init(body: "Hello"))
    }
    
    private func makeLiveLocationItem(isLive: Bool) -> LiveLocationRoomTimelineItem {
        .init(id: .randomEvent,
              timestamp: .mock,
              isOutgoing: false,
              isEditable: false,
              canBeRepliedTo: true,
              sender: .init(id: "@alice:matrix.org"),
              content: .init(isLive: isLive, timeoutDate: .mock, lastGeoURI: nil))
    }
    
    private func makeActions(for item: RoomTimelineItemProtocol, timelineKind: TimelineKind = .live) -> TimelineItemMenuActions? {
        TimelineItemMenuActionProvider(timelineItem: item,
                                       canCurrentUserSendMessage: true,
                                       canCurrentUserRedactSelf: true,
                                       canCurrentUserRedactOthers: false,
                                       canCurrentUserPin: true,
                                       pinnedEventIDs: [],
                                       isViewSourceEnabled: true,
                                       areThreadsEnabled: true,
                                       timelineKind: timelineKind,
                                       emojiProvider: EmojiProvider(userSettings: .mock()))
            .makeActions()
    }
}

private extension TimelineItemMenuAction {
    var isForward: Bool {
        if case .forward = self {
            return true
        }
        return false
    }
}
