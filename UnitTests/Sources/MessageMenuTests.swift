//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import XCTest

@MainActor
class MessageMenuTests: XCTestCase {
    override func setUp() {
        AppSettings.resetAllSettings()
    }

    // MARK: - Quick reactions

    func testQuickReactionsStartWithTheGuaSet() throws {
        let actions = try XCTUnwrap(makeActions(for: makeTextItem(isOutgoing: false)))

        XCTAssertEqual(actions.reactions.map(\.key), ["❤️", "👍️", "👎️", "😂", "‼️", "❓"])
        XCTAssertEqual(actions.reactions.map { Array($0.key.unicodeScalars).map(\.value) },
                       [[0x2764, 0xFE0F], [0x1F44D, 0xFE0F], [0x1F44E, 0xFE0F], [0x1F602], [0x203C, 0xFE0F], [0x2753]])
    }

    func testFrequentlyUsedReactionsFollowWithoutDuplicates() throws {
        let emojiProvider = EmojiProviderStub(frequentlyUsed: ["🔥", "❤️", "🙏", "😮", "😢", "🎉", "🥳"])
        let actions = try XCTUnwrap(makeActions(for: makeTextItem(isOutgoing: false), emojiProvider: emojiProvider))

        XCTAssertEqual(actions.reactions.map(\.key), ["❤️", "👍️", "👎️", "😂", "‼️", "❓", "🔥", "🙏", "😮", "😢"])
    }

    func testNoReactionsInThePinnedTimeline() throws {
        let actions = try XCTUnwrap(makeActions(for: makeTextItem(isOutgoing: false), timelineKind: .pinned))

        XCTAssertTrue(actions.reactions.isEmpty)
    }

    // MARK: - Action sections

    func testIncomingTextMessage() throws {
        let item = makeTextItem(isOutgoing: false)
        let actions = try XCTUnwrap(makeActions(for: item))
        let sections = MessageMenuSections(actions: actions.actions + actions.secondaryActions)

        XCTAssertEqual(sections.primary, [.reply(isThread: false), .copy, .select, .forward(itemID: item.id)])
        XCTAssertEqual(sections.more, [.pin, .copyPermalink, .report])
        XCTAssertEqual(sections.destructive, [])
    }

    func testOutgoingTextMessage() throws {
        let item = makeTextItem(isOutgoing: true)
        let actions = try XCTUnwrap(makeActions(for: item))
        let sections = MessageMenuSections(actions: actions.actions + actions.secondaryActions)

        XCTAssertEqual(sections.primary, [.reply(isThread: false), .copy, .select, .edit, .forward(itemID: item.id)])
        XCTAssertEqual(sections.more, [.pin, .copyPermalink])
        XCTAssertEqual(sections.destructive, [.redact])
    }

    func testMediaWithCaptionHasNoSelect() throws {
        let item = try XCTUnwrap(RoomTimelineItemFixtures.mediaChunk[5] as? EventBasedTimelineItemProtocol)
        let actions = try XCTUnwrap(makeActions(for: item))
        let sections = MessageMenuSections(actions: actions.actions + actions.secondaryActions)

        XCTAssertFalse(sections.primary.contains(.select))
        XCTAssertEqual(sections.primary.first, .reply(isThread: false))
        XCTAssertTrue(sections.primary.contains(.copyCaption))
        XCTAssertTrue(sections.primary.contains(.editCaption))
        XCTAssertEqual(sections.more.last, .removeCaption)
        XCTAssertEqual(sections.destructive, [.redact])
    }

    func testViewSourceAndThreadsGoUnderMore() throws {
        let actions = try XCTUnwrap(makeActions(for: makeTextItem(isOutgoing: false), isViewSourceEnabled: true, areThreadsEnabled: true))
        let sections = MessageMenuSections(actions: actions.actions + actions.secondaryActions)

        XCTAssertEqual(sections.more, [.replyInThread, .pin, .copyPermalink, .viewSource, .report])
    }

    func testEveryActionHasAPlaceExceptReactions() {
        let itemID = TimelineItemIdentifier.randomEvent
        let actions: [TimelineItemMenuAction] = [.copy, .copyCaption, .edit, .addCaption, .editCaption, .removeCaption, .editPoll,
                                                 .copyPermalink, .redact, .reply(isThread: false), .replyInThread, .forward(itemID: itemID),
                                                 .viewSource, .report, .endPoll(pollStartID: "poll"), .pin, .unpin,
                                                 .viewInRoomTimeline, .share, .save, .select]

        XCTAssertTrue(actions.allSatisfy { $0.messageMenuPlacement != nil })
        XCTAssertNil(TimelineItemMenuAction.react.messageMenuPlacement)
        XCTAssertNil(TimelineItemMenuAction.toggleReaction(key: "❤️").messageMenuPlacement)
    }

    // MARK: - Layout

    private let container = CGRect(x: 0, y: 60, width: 400, height: 760)

    func testBubbleWithRoomStaysWhereItWas() {
        let source = CGRect(x: 16, y: 300, width: 250, height: 80)
        let layout = MessageMenuLayout(sourceFrame: source, isOutgoing: false, container: container,
                                       reactionBarSize: CGSize(width: 330, height: 56), actionsSize: CGSize(width: 250, height: 200))

        XCTAssertEqual(layout.bubbleFrame, source)
        XCTAssertEqual(layout.reactionBarFrame, CGRect(x: 16, y: 236, width: 330, height: 56))
        XCTAssertEqual(layout.actionsFrame, CGRect(x: 16, y: 388, width: 250, height: 200))
    }

    func testBubbleNearTheTopMovesDownForTheReactions() {
        let source = CGRect(x: 16, y: 70, width: 250, height: 80)
        let layout = MessageMenuLayout(sourceFrame: source, isOutgoing: false, container: container,
                                       reactionBarSize: CGSize(width: 330, height: 56), actionsSize: nil)

        XCTAssertEqual(layout.bubbleFrame.minY, 60 + 56 + 8)
        XCTAssertEqual(layout.reactionBarFrame?.minY, 60)
        XCTAssertNil(layout.actionsFrame)
    }

    func testOutgoingBubbleNearTheBottomMovesUpAndAlignsTrailing() {
        let source = CGRect(x: 200, y: 760, width: 180, height: 44)
        let layout = MessageMenuLayout(sourceFrame: source, isOutgoing: true, container: container,
                                       reactionBarSize: CGSize(width: 330, height: 56), actionsSize: CGSize(width: 250, height: 300))

        XCTAssertEqual(layout.bubbleFrame.maxY, container.maxY - 300 - 8)
        XCTAssertEqual(layout.actionsFrame?.maxX, source.maxX)
        XCTAssertEqual(layout.reactionBarFrame?.maxX, source.maxX)
    }

    func testMenuStaysClearOfTheScreenEdges() {
        let source = CGRect(x: 230, y: 300, width: 168, height: 44)
        let layout = MessageMenuLayout(sourceFrame: source, isOutgoing: true, container: container,
                                       reactionBarSize: CGSize(width: 514, height: 56), actionsSize: CGSize(width: 250, height: 200))

        XCTAssertEqual(layout.reactionBarFrame, CGRect(x: 12, y: 236, width: 376, height: 56))
        XCTAssertEqual(layout.actionsFrame?.maxX, container.maxX - MessageMenuLayout.margin)
    }

    func testTallBubbleIsClippedToTheSpaceLeft() {
        let source = CGRect(x: 16, y: 0, width: 300, height: 2000)
        let layout = MessageMenuLayout(sourceFrame: source, isOutgoing: false, container: container,
                                       reactionBarSize: CGSize(width: 330, height: 56), actionsSize: CGSize(width: 250, height: 300))

        XCTAssertEqual(layout.bubbleFrame.minY, 60 + 56 + 8)
        XCTAssertEqual(layout.bubbleFrame.height, 760 - 56 - 8 - 300 - 8)
    }

    // MARK: - View model

    func testDoubleTapShowsReactionsOverTheBubble() async throws {
        let item = makeTextItem(isOutgoing: false)
        let viewModel = makeViewModel(items: [item])
        let sourceFrame = CGRect(x: 16, y: 300, width: 250, height: 80)

        let deferred = deferFulfillment(viewModel.context.$viewState) { $0.bindings.actionMenuInfo != nil }
        viewModel.context.send(viewAction: .displayTimelineItemMenu(itemID: item.id, presentation: .reactions(sourceFrame: sourceFrame)))
        try await deferred.fulfill()

        XCTAssertEqual(viewModel.context.actionMenuInfo?.id, item.id)
        XCTAssertEqual(viewModel.context.actionMenuInfo?.presentation, .reactions(sourceFrame: sourceFrame))
        XCTAssertEqual(viewModel.context.actionMenuInfo?.presentation.showsActions, false)
    }

    func testLongPressShowsReactionsAndActions() async throws {
        let item = makeTextItem(isOutgoing: true)
        let viewModel = makeViewModel(items: [item])
        let sourceFrame = CGRect(x: 120, y: 500, width: 250, height: 44)

        let deferred = deferFulfillment(viewModel.context.$viewState) { $0.bindings.actionMenuInfo != nil }
        viewModel.context.send(viewAction: .displayTimelineItemMenu(itemID: item.id, presentation: .reactionsAndActions(sourceFrame: sourceFrame)))
        try await deferred.fulfill()

        XCTAssertEqual(viewModel.context.actionMenuInfo?.presentation, .reactionsAndActions(sourceFrame: sourceFrame))
        XCTAssertEqual(viewModel.context.actionMenuInfo?.presentation.showsActions, true)
    }

    func testAccessibilityStillUsesTheSheet() async throws {
        let item = makeTextItem(isOutgoing: false)
        let viewModel = makeViewModel(items: [item])

        let deferred = deferFulfillment(viewModel.context.$viewState) { $0.bindings.actionMenuInfo != nil }
        viewModel.context.send(viewAction: .displayTimelineItemMenu(itemID: item.id))
        try await deferred.fulfill()

        XCTAssertEqual(viewModel.context.actionMenuInfo?.presentation, .sheet)
    }

    func testSelectShowsTheMessageText() async throws {
        let item = makeTextItem(isOutgoing: false, body: "Que paz nesse lugar 😍")
        let viewModel = makeViewModel(items: [item])

        let deferred = deferFulfillment(viewModel.context.$viewState) { $0.bindings.textSelectionInfo != nil }
        viewModel.context.send(viewAction: .handleTimelineItemMenuAction(itemID: item.id, action: .select))
        try await deferred.fulfill()

        XCTAssertEqual(viewModel.context.textSelectionInfo, TimelineItemTextSelectionInfo(id: item.id, text: "Que paz nesse lugar 😍"))
    }

    // MARK: - Helpers

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
                                       isDM: true,
                                       isViewSourceEnabled: isViewSourceEnabled,
                                       areThreadsEnabled: areThreadsEnabled,
                                       timelineKind: timelineKind,
                                       emojiProvider: emojiProvider)
            .makeActions()
    }

    private func makeViewModel(items: [RoomTimelineItemProtocol]) -> TimelineViewModel {
        let timelineController = MockTimelineController()
        timelineController.timelineItems = items

        return TimelineViewModel(roomProxy: JoinedRoomProxyMock(.init(name: "")),
                                 timelineController: timelineController,
                                 userSession: UserSessionMock(.init()),
                                 mediaPlayerProvider: MediaPlayerProviderMock(),
                                 userIndicatorController: UserIndicatorControllerMock.default,
                                 appMediator: AppMediatorMock.default,
                                 appSettings: ServiceLocator.shared.settings,
                                 analyticsService: ServiceLocator.shared.analytics,
                                 emojiProvider: EmojiProvider(appSettings: ServiceLocator.shared.settings),
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
