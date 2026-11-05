//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing
import UIKit

@MainActor
final class MessageMenuTests {
    // MARK: - Quick reactions
    
    @Test
    func quickReactionsStartWithTheGuaSet() throws {
        let actions = try #require(makeActions(for: makeTextItem(isOutgoing: false)))
        
        #expect(actions.reactions.map { Array($0.key.unicodeScalars).map(\.value) } == [[0x2764, 0xFE0F], [0x1F44D, 0xFE0F], [0x1F44E, 0xFE0F], [0x1F602], [0x203C, 0xFE0F], [0x2753, 0xFE0F]])
    }
    
    @Test
    func frequentlyUsedReactionsFollowWithoutDuplicates() throws {
        let emojiProvider = EmojiProviderStub(frequentlyUsed: ["🔥", "❤️", "🙏", "😮", "😢", "🎉", "🥳"])
        let actions = try #require(makeActions(for: makeTextItem(isOutgoing: false), emojiProvider: emojiProvider))
        
        #expect(actions.reactions.map(\.key) == ["❤️", "👍️", "👎️", "😂", "‼️", "❓\u{FE0F}", "🔥", "🙏", "😮", "😢"])
    }
    
    @Test
    func noReactionsInThePinnedTimeline() throws {
        let actions = try #require(makeActions(for: makeTextItem(isOutgoing: false), timelineKind: .pinned))
        
        #expect(actions.reactions.isEmpty)
    }
    
    // MARK: - Action sections
    
    @Test
    func incomingTextMessage() throws {
        let item = makeTextItem(isOutgoing: false)
        let actions = try #require(makeActions(for: item))
        let sections = MessageMenuSections(actions: actions.actions + actions.secondaryActions)
        
        #expect(sections.primary == [.reply(isThread: false), .copy, .select, .translate, .forward(itemID: item.id)])
        #expect(sections.more == [.pin, .copyPermalink, .report])
        #expect(sections.destructive == [])
    }
    
    @Test
    func outgoingTextMessage() throws {
        let item = makeTextItem(isOutgoing: true)
        let actions = try #require(makeActions(for: item))
        let sections = MessageMenuSections(actions: actions.actions + actions.secondaryActions)
        
        #expect(sections.primary == [.reply(isThread: false), .copy, .select, .translate, .edit, .forward(itemID: item.id)])
        #expect(sections.more == [.pin, .copyPermalink])
        #expect(sections.destructive == [.redact(isMedia: false)])
    }
    
    @Test
    func mediaWithCaptionHasNoSelect() throws {
        let item = try #require(TimelineFixtures.mediaChunk[5] as? EventBasedTimelineItemProtocol)
        let actions = try #require(makeActions(for: item))
        let sections = MessageMenuSections(actions: actions.actions + actions.secondaryActions)
        
        #expect(!sections.primary.contains(.select))
        #expect(sections.primary.first == .reply(isThread: false))
        #expect(sections.primary.contains(.copyCaption))
        #expect(sections.primary.contains(.editCaption))
        #expect(sections.more.last == .removeCaption)
        #expect(sections.destructive == [.redact(isMedia: false)])
    }
    
    @Test
    func viewSourceAndThreadsGoUnderMore() throws {
        let actions = try #require(makeActions(for: makeTextItem(isOutgoing: false), isViewSourceEnabled: true, areThreadsEnabled: true))
        let sections = MessageMenuSections(actions: actions.actions + actions.secondaryActions)
        
        #expect(sections.more == [.replyInThread, .pin, .copyPermalink, .viewSource, .report])
    }
    
    @Test
    func everyActionHasAPlaceExceptReactions() {
        let itemID = TimelineItemIdentifier.randomEvent
        let actions: [TimelineItemMenuAction] = [.copy, .translate, .copyCaption, .edit, .addCaption, .editCaption, .removeCaption, .editPoll,
                                                 .copyPermalink, .redact(isMedia: false), .reply(isThread: false), .replyInThread, .forward(itemID: itemID),
                                                 .viewSource, .report, .endPoll(pollStartID: "poll"), .pin, .unpin,
                                                 .viewInRoomTimeline, .downloadMedia, .select]
        
        #expect(actions.allSatisfy { $0.messageMenuPlacement != nil })
        #expect(TimelineItemMenuAction.react.messageMenuPlacement == nil)
        #expect(TimelineItemMenuAction.toggleReaction(key: "❤️").messageMenuPlacement == nil)
    }
    
    // MARK: - Layout
    
    private let container = CGRect(x: 0, y: 60, width: 400, height: 760)
    
    @Test
    func bubbleWithRoomStaysWhereItWas() {
        let source = CGRect(x: 16, y: 300, width: 250, height: 80)
        let layout = MessageMenuLayout(sourceFrame: source, alignsRight: false, container: container,
                                       reactionBarSize: CGSize(width: 330, height: 56), detailsSize: CGSize(width: 250, height: 200))
        
        #expect(layout.bubbleFrame == source)
        #expect(layout.reactionBarFrame == CGRect(x: 16, y: 236, width: 330, height: 56))
        #expect(layout.detailsFrame == CGRect(x: 16, y: 388, width: 250, height: 200))
    }
    
    @Test
    func bubbleNearTheTopMovesDownForTheReactions() {
        let source = CGRect(x: 16, y: 70, width: 250, height: 80)
        let layout = MessageMenuLayout(sourceFrame: source, alignsRight: false, container: container,
                                       reactionBarSize: CGSize(width: 330, height: 56), detailsSize: nil)
        
        #expect(layout.bubbleFrame.minY == CGFloat(60 + 56 + 8))
        #expect(layout.reactionBarFrame?.minY == 60)
        #expect(layout.detailsFrame == nil)
    }
    
    @Test
    func outgoingBubbleNearTheBottomMovesUpAndAlignsTrailing() {
        let source = CGRect(x: 200, y: 760, width: 180, height: 44)
        let layout = MessageMenuLayout(sourceFrame: source, alignsRight: true, container: container,
                                       reactionBarSize: CGSize(width: 330, height: 56), detailsSize: CGSize(width: 250, height: 300))
        
        #expect(layout.bubbleFrame.maxY == container.maxY - 300 - 8)
        #expect(layout.detailsFrame?.maxX == source.maxX)
        #expect(layout.reactionBarFrame?.maxX == source.maxX)
    }
    
    @Test
    func menuStaysClearOfTheScreenEdges() {
        let source = CGRect(x: 230, y: 300, width: 168, height: 44)
        let layout = MessageMenuLayout(sourceFrame: source, alignsRight: true, container: container,
                                       reactionBarSize: CGSize(width: 514, height: 56), detailsSize: CGSize(width: 250, height: 200))
        
        #expect(layout.reactionBarFrame == CGRect(x: 12, y: 236, width: 376, height: 56))
        #expect(layout.detailsFrame?.maxX == container.maxX - MessageMenuLayout.margin)
    }
    
    @Test
    func tallBubbleIsClippedToTheSpaceLeft() {
        let source = CGRect(x: 16, y: 0, width: 300, height: 2000)
        let layout = MessageMenuLayout(sourceFrame: source, alignsRight: false, container: container,
                                       reactionBarSize: CGSize(width: 330, height: 56), detailsSize: CGSize(width: 250, height: 300))
        
        #expect(layout.bubbleFrame.minY == CGFloat(60 + 56 + 8))
        #expect(layout.bubbleFrame.height == CGFloat(760 - 56 - 8 - 300 - 8))
    }
    
    @Test
    func landscapeKeepsTheBubbleVisibleAndScrollsTheCard() {
        let landscape = CGRect(x: 0, y: 8, width: 850, height: 356)
        let source = CGRect(x: 600, y: 250, width: 200, height: 44)
        let layout = MessageMenuLayout(sourceFrame: source, alignsRight: true, container: landscape,
                                       reactionBarSize: CGSize(width: 330, height: 56), detailsSize: CGSize(width: 250, height: 342))
        
        #expect(layout.bubbleFrame.height == 44)
        #expect(layout.reactionBarFrame?.minY == landscape.minY)
        #expect(layout.detailsFrame?.height == CGFloat(356 - 56 - 8 - 44 - 8))
        #expect(layout.detailsFrame?.maxY == landscape.maxY)
    }
    
    @Test
    func bubbleOutsideTheScreenIsPulledBackIn() {
        let source = CGRect(x: 500, y: 300, width: 200, height: 44)
        let layout = MessageMenuLayout(sourceFrame: source, alignsRight: true, container: container,
                                       reactionBarSize: nil, detailsSize: nil)
        
        #expect(layout.bubbleFrame == CGRect(x: 200, y: 300, width: 200, height: 44))
    }
    
    // MARK: - Who reacted
    
    @Test
    func whoReactedListsTheCurrentUserFirstThenOldestFirst() {
        let reactions = [
            AggregatedReaction(accountOwnerID: "@me:gua", key: "❤️", senders: [sender("@rafa:gua", 3), sender("@me:gua", 5), sender("@camila:gua", 1)]),
            AggregatedReaction(accountOwnerID: "@me:gua", key: "😂", senders: [sender("@bia:gua", 2)])
        ]
        
        let rows = MessageReactionSummaryRow.rows(for: reactions)
        
        #expect(rows.map(\.id) == ["@me:gua", "@camila:gua", "@bia:gua", "@rafa:gua"])
        #expect(rows.map(\.isOwnUser) == [true, false, false, false])
    }
    
    @Test
    func whoReactedGroupsEachPersonsEmojiInMessageOrder() {
        let reactions = [
            AggregatedReaction(accountOwnerID: "@me:gua", key: "👍️", senders: [sender("@camila:gua", 4)]),
            AggregatedReaction(accountOwnerID: "@me:gua", key: "❤️", senders: [sender("@camila:gua", 1), sender("@rafa:gua", 1)])
        ]
        
        let rows = MessageReactionSummaryRow.rows(for: reactions)
        
        #expect(rows == [MessageReactionSummaryRow(id: "@camila:gua", isOwnUser: false, keys: ["👍️", "❤️"]),
                         MessageReactionSummaryRow(id: "@rafa:gua", isOwnUser: false, keys: ["❤️"])])
    }
    
    @Test
    func whoReactedShortensLongTextReactions() {
        let reactions = [AggregatedReaction(accountOwnerID: "@me:gua", key: "this is the best news I have heard all year", senders: [sender("@rafa:gua", 1)])]
        
        #expect(MessageReactionSummaryRow.rows(for: reactions).first?.keys == [reactions[0].displayKey])
        #expect(reactions[0].displayKey.count < reactions[0].key.count)
    }
    
    @Test
    func noReactionsMeansNobodyToList() {
        #expect(MessageReactionSummaryRow.rows(for: []) == [])
    }
    
    // MARK: - View model
    
    @Test
    func doubleTapShowsReactionsOverTheBubble() async throws {
        let item = makeTextItem(isOutgoing: false)
        let viewModel = makeViewModel(items: [item])
        let anchor = MessageMenuAnchor(frame: CGRect(x: 16, y: 300, width: 250, height: 80))
        
        let deferred = deferFulfillment(viewModel.context.$viewState) { $0.bindings.actionMenuInfo != nil }
        viewModel.context.send(viewAction: .displayTimelineItemMenu(itemID: item.id, presentation: .reactions(anchor)))
        try await deferred.fulfill()
        
        #expect(viewModel.context.actionMenuInfo?.id == item.id)
        #expect(viewModel.context.actionMenuInfo?.presentation == .reactions(anchor))
        #expect(viewModel.context.actionMenuInfo?.presentation.showsActions == false)
    }
    
    @Test
    func longPressShowsReactionsAndActions() async throws {
        let item = makeTextItem(isOutgoing: true)
        let viewModel = makeViewModel(items: [item])
        let anchor = MessageMenuAnchor(frame: CGRect(x: 120, y: 500, width: 250, height: 44))
        
        let deferred = deferFulfillment(viewModel.context.$viewState) { $0.bindings.actionMenuInfo != nil }
        viewModel.context.send(viewAction: .displayTimelineItemMenu(itemID: item.id, presentation: .reactionsAndActions(anchor)))
        try await deferred.fulfill()
        
        #expect(viewModel.context.actionMenuInfo?.presentation == .reactionsAndActions(anchor))
        #expect(viewModel.context.actionMenuInfo?.presentation.showsActions == true)
    }
    
    @Test
    func longPressOnARemovedMessageOpensNothing() async throws {
        let item = RedactedRoomTimelineItem(id: .randomEvent,
                                            body: "Message removed",
                                            timestamp: .mock,
                                            isOutgoing: false,
                                            isEditable: false,
                                            canBeRepliedTo: false,
                                            sender: .init(id: "@camila:gua"))
        let viewModel = makeViewModel(items: [item], isViewSourceEnabled: false)
        
        viewModel.context.send(viewAction: .displayTimelineItemMenu(itemID: item.id, presentation: .reactionsAndActions(MessageMenuAnchor(frame: .zero))))
        try await Task.sleep(for: .milliseconds(300))
        
        #expect(viewModel.context.actionMenuInfo == nil)
    }
    
    @Test
    func accessibilityStillUsesTheSheet() async throws {
        let item = makeTextItem(isOutgoing: false)
        let viewModel = makeViewModel(items: [item])
        
        let deferred = deferFulfillment(viewModel.context.$viewState) { $0.bindings.actionMenuInfo != nil }
        viewModel.context.send(viewAction: .displayTimelineItemMenu(itemID: item.id))
        try await deferred.fulfill()
        
        #expect(viewModel.context.actionMenuInfo?.presentation == .sheet)
    }
    
    @Test
    func bubbleFrameIgnoresCopiesOutsideTheWindow() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let bubble = UIView(frame: CGRect(x: 16, y: 300, width: 250, height: 80))
        window.addSubview(bubble)
        let earlierCopy = UIView(frame: bubble.bounds)
        let accessibilityCopy = UIView(frame: bubble.bounds)
        let reader = WindowFrameReader()
        
        reader.track(earlierCopy)
        reader.track(bubble)
        reader.track(accessibilityCopy)
        
        #expect(reader.frame == CGRect(x: 16, y: 300, width: 250, height: 80))
    }
    
    @Test
    func gesturesAnchorTheMenusToTheBubbleOnScreen() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let bubble = UIView(frame: CGRect(x: 120, y: 500, width: 250, height: 44))
        window.addSubview(bubble)
        let accessibilityCopy = UIView(frame: bubble.bounds)
        let reader = WindowFrameReader()
        reader.track(bubble)
        reader.track(accessibilityCopy)
        
        let doubleTap = TimelineItemMenuPresentation.floating(showsActions: false, over: reader)
        let longPress = TimelineItemMenuPresentation.floating(showsActions: true, over: reader)
        
        #expect(doubleTap.anchor?.frame == CGRect(x: 120, y: 500, width: 250, height: 44))
        #expect(!doubleTap.showsActions)
        #expect(longPress.anchor?.frame == CGRect(x: 120, y: 500, width: 250, height: 44))
        #expect(longPress.showsActions)
        
        bubble.frame.origin.y = 320
        
        #expect(doubleTap.anchor?.frame == CGRect(x: 120, y: 320, width: 250, height: 44))
    }
    
    @Test
    func gesturesOpenTheSheetWhenTheBubbleIsOffScreen() {
        let detachedBubble = UIView(frame: CGRect(x: 16, y: 300, width: 250, height: 80))
        let reader = WindowFrameReader()
        reader.track(detachedBubble)
        
        #expect(reader.frame == nil)
        #expect(TimelineItemMenuPresentation.floating(showsActions: false, over: reader) == .sheet)
        #expect(TimelineItemMenuPresentation.floating(showsActions: true, over: reader) == .sheet)
    }
    
    @Test
    func selectShowsTheMessageText() async throws {
        let item = makeTextItem(isOutgoing: false, body: "Que paz nesse lugar 😍")
        let viewModel = makeViewModel(items: [item])
        
        let deferred = deferFulfillment(viewModel.context.$viewState) { $0.bindings.textSelectionInfo != nil }
        viewModel.context.send(viewAction: .handleTimelineItemMenuAction(itemID: item.id, action: .select))
        try await deferred.fulfill()
        
        #expect(viewModel.context.textSelectionInfo == TimelineItemTextSelectionInfo(id: item.id, text: "Que paz nesse lugar 😍"))
    }
    
    @Test
    func selectWritesMentionsOutLikeTheirPills() async throws {
        let formattedBody = AttributedStringBuilder(mentionBuilder: MentionBuilder())
            .fromHTML("Oi <a href=\"https://matrix.to/#/@camila:gua.global\">Camila</a>, tudo bem?")
        let item = TextRoomTimelineItem(id: .randomEvent,
                                        timestamp: .mock,
                                        isOutgoing: false,
                                        isEditable: false,
                                        canBeRepliedTo: true,
                                        sender: .init(id: "@rafa:gua"),
                                        content: .init(body: "Oi [Camila](https://matrix.to/#/@camila:gua.global), tudo bem?", formattedBody: formattedBody))
        let viewModel = makeViewModel(items: [item])
        
        let deferred = deferFulfillment(viewModel.context.$viewState) { $0.bindings.textSelectionInfo != nil }
        viewModel.context.send(viewAction: .handleTimelineItemMenuAction(itemID: item.id, action: .select))
        try await deferred.fulfill()
        
        #expect(viewModel.context.textSelectionInfo?.text == "Oi @camila, tudo bem?")
    }
    
    @Test
    func selectionTextKeepsPlainBodiesAsTheyAre() {
        #expect(MessageSelectionText.make(body: "**not markdown here**", formattedBody: nil) { _ in "" } == "**not markdown here**")
    }
    
    // MARK: - Helpers
    
    private func sender(_ id: String, _ minute: Double) -> ReactionSender {
        ReactionSender(id: id, timestamp: Date(timeIntervalSince1970: minute * 60))
    }
    
    private func makeTextItem(isOutgoing: Bool, body: String = "Me mudei pra Floripa ano passado") -> TextRoomTimelineItem {
        TextRoomTimelineItem(id: .randomEvent,
                             timestamp: .mock,
                             isOutgoing: isOutgoing,
                             isEditable: isOutgoing,
                             canBeRepliedTo: true,
                             sender: .init(id: isOutgoing ? "@me:gua" : "@camila:gua"),
                             content: .init(body: body))
    }
    
    private func makeActions(for item: EventBasedTimelineItemProtocol,
                             timelineKind: TimelineKind = .live,
                             isViewSourceEnabled: Bool = false,
                             areThreadsEnabled: Bool = false,
                             emojiProvider: EmojiProviderProtocol = EmojiProviderStub(frequentlyUsed: [])) -> TimelineItemMenuActions? {
        TimelineItemMenuActionProvider(timelineItem: item,
                                       canCurrentUserSendMessage: true,
                                       canCurrentUserRedactSelf: true,
                                       canCurrentUserRedactOthers: false,
                                       canCurrentUserPin: true,
                                       pinnedEventIDs: [],
                                       isViewSourceEnabled: isViewSourceEnabled,
                                       areThreadsEnabled: areThreadsEnabled,
                                       timelineKind: timelineKind,
                                       emojiProvider: emojiProvider)
            .makeActions()
    }
    
    private func makeViewModel(items: [RoomTimelineItemProtocol], isViewSourceEnabled: Bool? = nil) -> TimelineViewModel {
        let userSettings = UserSettings.mock()
        if let isViewSourceEnabled {
            userSettings.app.viewSourceEnabled = isViewSourceEnabled
        }
        
        return TimelineViewModel(roomProxy: JoinedRoomProxyMock(.init(name: "")),
                                 timelineController: TimelineControllerMock(.init(timelineItems: items)),
                                 userSession: UserSessionMock(.init(userSettings: userSettings)),
                                 mediaPlayerProvider: MediaPlayerProviderMock(),
                                 userIndicatorController: UserIndicatorControllerMock(),
                                 appMediator: AppMediatorMock(.init()),
                                 analyticsService: AnalyticsServiceMock(.init()),
                                 emojiProvider: EmojiProvider(userSettings: userSettings),
                                 linkMetadataProvider: LinkMetadataProvider(),
                                 timelineControllerFactory: TimelineControllerFactoryMock(.init()))
    }
}

private struct EmojiProviderStub: EmojiProviderProtocol {
    let frequentlyUsed: [String]
    
    var state: EmojiProviderState {
        .notLoaded
    }
    
    func categories(searchString: String?) async -> [EmojiCategory] {
        []
    }
    
    func frequentlyUsedSystemEmojis() -> [String] {
        frequentlyUsed
    }
    
    func markEmojiAsFrequentlyUsed(_ emoji: String) { }
}
