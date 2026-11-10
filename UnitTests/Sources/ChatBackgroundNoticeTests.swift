//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import MatrixRustSDK
import MatrixRustSDKMocks
import Testing

@MainActor
final class ChatBackgroundNoticeTests {
    private let ownUserID = "@alice:gua.global"
    private let otherUserID = "@bob:gua.global"
    
    @Test
    func noticeStrings() {
        let builder = RoomStateEventStringBuilder(userID: ownUserID)
        let you = TimelineItemSender(id: ownUserID, displayName: "Alice")
        let bob = TimelineItemSender(id: otherUserID, displayName: "Bob")
        let handleOnly = TimelineItemSender(id: otherUserID)
        
        #expect(builder.buildChatThemeString(isRemoval: false, sender: you, isOutgoing: true) == UntranslatedL10n.guaChatThemeNoticeChangedByYou)
        #expect(builder.buildChatThemeString(isRemoval: true, sender: you, isOutgoing: true) == UntranslatedL10n.guaChatThemeNoticeRemovedByYou)
        #expect(builder.buildChatThemeString(isRemoval: false, sender: bob, isOutgoing: false) == UntranslatedL10n.guaChatThemeNoticeChanged("Bob"))
        #expect(builder.buildChatThemeString(isRemoval: true, sender: bob, isOutgoing: false) == UntranslatedL10n.guaChatThemeNoticeRemoved("Bob"))
        #expect(builder.buildChatThemeString(isRemoval: false, sender: handleOnly, isOutgoing: false) == UntranslatedL10n.guaChatThemeNoticeChanged(otherUserID.guaDisplayHandle))
    }
    
    @Test
    func theChatListNeverShowsTheNotice() {
        let builder = RoomStateEventStringBuilder(userID: ownUserID)
        #expect(builder.buildString(for: .custom(eventType: ChatBackground.eventType),
                                    sender: TimelineItemSender(id: otherUserID, displayName: "Bob"),
                                    isOutgoing: false) == nil)
    }
    
    @Test
    func noticeIsShownInGroupsAndInOneToOneChats() throws {
        for isDM in [false, true] {
            let item = try #require(buildItem(content: #"{"v":1,"kind":"preset","preset":"mint"}"#, isDM: isDM) as? StateRoomTimelineItem, "isDM: \(isDM)")
            #expect(item.body == UntranslatedL10n.guaChatThemeNoticeChanged("Bob"))
            #expect(item.chatBackgroundEvent?.eventID == "$background")
            #expect(item.chatBackgroundEvent?.timestamp == 1_730_000_000_123)
            #expect(ChatTheme(contentJSON: item.chatBackgroundEvent?.contentJSON) == ChatTheme(wallpaper: .preset(.mint)))
            #expect(!item.canBeRepliedTo)
        }
    }
    
    @Test
    func emptyContentReadsAsRemoved() throws {
        let item = try #require(buildItem(content: "{}", isDM: false) as? StateRoomTimelineItem)
        #expect(item.body == UntranslatedL10n.guaChatThemeNoticeRemoved("Bob"))
        #expect(item.chatBackgroundEvent?.isRemoval == true)
    }
    
    @Test
    func unreadableContentReadsAsChanged() throws {
        let item = try #require(buildItem(eventJSON: nil, isDM: false) as? StateRoomTimelineItem)
        #expect(item.body == UntranslatedL10n.guaChatThemeNoticeChanged("Bob"))
        #expect(item.chatBackgroundEvent?.contentJSON == nil)
    }
    
    @Test
    func otherCustomStateIsStillHidden() {
        #expect(buildItem(eventType: "global.gua.something.else", content: "{}", isDM: false) == nil)
        #expect(buildItem(stateKey: "@bob:gua.global", content: #"{"v":1,"kind":"preset","preset":"mint"}"#, isDM: false) == nil)
    }
    
    private func buildItem(eventType: String = ChatBackground.eventType,
                           stateKey: String = "",
                           content: String,
                           isDM: Bool) -> RoomTimelineItemProtocol? {
        buildItem(eventType: eventType,
                  stateKey: stateKey,
                  eventJSON: #"{"type":"\#(eventType)","state_key":"\#(stateKey)","sender":"\#(otherUserID)","content":\#(content)}"#,
                  isDM: isDM)
    }
    
    private func buildItem(eventType: String = ChatBackground.eventType,
                           stateKey: String = "",
                           eventJSON: String?,
                           isDM: Bool) -> RoomTimelineItemProtocol? {
        let factory = RoomTimelineItemFactory(userID: ownUserID,
                                              attributedStringBuilder: AttributedStringBuilder(mentionBuilder: MentionBuilder()),
                                              stateEventStringBuilder: RoomStateEventStringBuilder(userID: ownUserID, isDirectOneToOneRoom: isDM))
        let lazyProvider = LazyTimelineItemProviderSDKMock()
        lazyProvider.debugInfoReturnValue = EventTimelineItemDebugInfo(model: "", originalJson: eventJSON, latestEditJson: nil)
        let item = EventTimelineItem(isRemote: true,
                                     eventOrTransactionId: .eventId(eventId: "$background"),
                                     sender: otherUserID,
                                     senderProfile: .ready(displayName: "Bob", displayNameAmbiguous: false, avatarUrl: nil, status: nil, call: nil),
                                     forwarder: nil,
                                     forwarderProfile: nil,
                                     isOwn: false,
                                     isEditable: false,
                                     content: .state(stateKey: stateKey, content: .custom(eventType: eventType)),
                                     reactions: [],
                                     eventTypeRaw: nil,
                                     timestamp: 1_730_000_000_123,
                                     localSendState: nil,
                                     editSendState: nil,
                                     redactionSendState: nil,
                                     redactionReason: nil,
                                     localCreatedAt: nil,
                                     readReceipts: [:],
                                     origin: nil,
                                     canBeRepliedTo: true,
                                     lazyProvider: lazyProvider)
        return factory.buildTimelineItem(for: EventTimelineItemProxy(item: item, uniqueID: .init("background")), isDM: isDM)
    }
}
