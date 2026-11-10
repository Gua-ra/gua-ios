//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import MatrixRustSDK
import XCTest

@MainActor
final class ChatBackgroundNoticeTests: XCTestCase {
    private let ownUserID = "@alice:gua.global"
    private let otherUserID = "@bob:gua.global"

    func testNoticeStrings() {
        let builder = RoomStateEventStringBuilder(userID: ownUserID)
        let you = TimelineItemSender(id: ownUserID, displayName: "Alice")
        let bob = TimelineItemSender(id: otherUserID, displayName: "Bob")
        let handleOnly = TimelineItemSender(id: otherUserID)

        XCTAssertEqual(builder.buildChatThemeString(isRemoval: false, sender: you, isOutgoing: true),
                       UntranslatedL10n.guaChatThemeNoticeChangedByYou)
        XCTAssertEqual(builder.buildChatThemeString(isRemoval: true, sender: you, isOutgoing: true),
                       UntranslatedL10n.guaChatThemeNoticeRemovedByYou)
        XCTAssertEqual(builder.buildChatThemeString(isRemoval: false, sender: bob, isOutgoing: false),
                       UntranslatedL10n.guaChatThemeNoticeChanged("Bob"))
        XCTAssertEqual(builder.buildChatThemeString(isRemoval: true, sender: bob, isOutgoing: false),
                       UntranslatedL10n.guaChatThemeNoticeRemoved("Bob"))
        XCTAssertEqual(builder.buildChatThemeString(isRemoval: false, sender: handleOnly, isOutgoing: false),
                       UntranslatedL10n.guaChatThemeNoticeChanged(otherUserID.guaDisplayHandle))
    }

    func testTheChatListNeverShowsTheNotice() {
        let builder = RoomStateEventStringBuilder(userID: ownUserID, shouldDisambiguateDisplayNames: false)
        XCTAssertNil(builder.buildString(for: .custom(eventType: ChatBackground.eventType),
                                         sender: TimelineItemSender(id: otherUserID, displayName: "Bob"),
                                         isOutgoing: false))
    }

    func testNoticeIsShownInGroupsAndInOneToOneChats() throws {
        for isDM in [false, true] {
            let item = try XCTUnwrap(buildItem(content: #"{"v":1,"kind":"preset","preset":"mint"}"#, isDM: isDM) as? StateRoomTimelineItem, "isDM: \(isDM)")
            XCTAssertEqual(item.body, UntranslatedL10n.guaChatThemeNoticeChanged("Bob"))
            XCTAssertEqual(item.chatBackgroundEvent?.eventID, "$background")
            XCTAssertEqual(item.chatBackgroundEvent?.timestamp, 1_730_000_000_123)
            XCTAssertEqual(ChatTheme(contentJSON: item.chatBackgroundEvent?.contentJSON), ChatTheme(wallpaper: .preset(.mint)))
            XCTAssertFalse(item.canBeRepliedTo)
        }
    }

    func testEmptyContentReadsAsRemoved() throws {
        let item = try XCTUnwrap(buildItem(content: "{}", isDM: false) as? StateRoomTimelineItem)
        XCTAssertEqual(item.body, UntranslatedL10n.guaChatThemeNoticeRemoved("Bob"))
        XCTAssertEqual(item.chatBackgroundEvent?.isRemoval, true)
    }

    func testUnreadableContentReadsAsChanged() throws {
        let item = try XCTUnwrap(buildItem(eventJSON: nil, isDM: false) as? StateRoomTimelineItem)
        XCTAssertEqual(item.body, UntranslatedL10n.guaChatThemeNoticeChanged("Bob"))
        XCTAssertNil(item.chatBackgroundEvent?.contentJSON)
    }

    func testOtherCustomStateIsStillHidden() {
        XCTAssertNil(buildItem(eventType: "global.gua.something.else", content: "{}", isDM: false))
        XCTAssertNil(buildItem(stateKey: "@bob:gua.global", content: #"{"v":1,"kind":"preset","preset":"mint"}"#, isDM: false))
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
                                     senderProfile: .ready(displayName: "Bob", displayNameAmbiguous: false, avatarUrl: nil),
                                     forwarder: nil,
                                     forwarderProfile: nil,
                                     isOwn: false,
                                     isEditable: false,
                                     content: .state(stateKey: stateKey, content: .custom(eventType: eventType)),
                                     eventTypeRaw: nil,
                                     timestamp: 1_730_000_000_123,
                                     localSendState: nil,
                                     localCreatedAt: nil,
                                     readReceipts: [:],
                                     origin: nil,
                                     canBeRepliedTo: true,
                                     lazyProvider: lazyProvider)
        return factory.buildTimelineItem(for: EventTimelineItemProxy(item: item, uniqueID: .init("background")), isDM: isDM)
    }
}
