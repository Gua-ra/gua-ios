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
final class ChatBackgroundTimelineTests: XCTestCase {
    private let otherUserID = "@bob:gua.global"

    func testMainTimelineReportsTheNewestChangeAndShowsTheTheme() async throws {
        let theme = ChatTheme(wallpaper: .preset(.night), bubble: .purple)
        let service = ChatBackgroundServiceMock(.init(theme: theme, defaultTheme: ChatTheme(wallpaper: .preset(.aurora))))
        let refreshed = expectation(description: "The server's state is read when the chat opens")
        service.refreshRoomIDClosure = { _ in refreshed.fulfill() }
        let older = noticeItem(eventID: "$older", timestamp: 100, background: .preset(.sky))
        let newer = noticeItem(eventID: "$newer", timestamp: 200, background: .preset(.night))
        let timelineController = MockTimelineController(timelineItems: [newer, older])

        let viewModel = makeTimelineViewModel(timelineController: timelineController, service: service)
        await fulfillment(of: [refreshed], timeout: 1)

        XCTAssertEqual(viewModel.context.viewState.chatTheme, theme)
        XCTAssertEqual(viewModel.context.viewState.effectiveChatTheme, theme)
        XCTAssertEqual(service.handleTimelineEventRoomIDEventIDTimestampContentJSONCallsCount, 1)
        XCTAssertEqual(service.handleTimelineEventRoomIDEventIDTimestampContentJSONReceivedArguments?.eventID, "$newer")
        XCTAssertEqual(service.handleTimelineEventRoomIDEventIDTimestampContentJSONReceivedArguments?.timestamp, 200)

        timelineController.callbacks.send(.updatedTimelineItems(timelineItems: [newer, older], isSwitchingTimelines: false))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(service.handleTimelineEventRoomIDEventIDTimestampContentJSONCallsCount, 1)
    }

    func testDefaultThemeShowsInAChatWithoutATheme() {
        let defaultTheme = ChatTheme(wallpaper: .preset(.dusk), bubble: .orange)
        let service = ChatBackgroundServiceMock(.init(defaultTheme: defaultTheme))

        let viewModel = makeTimelineViewModel(timelineController: MockTimelineController(timelineItems: []), service: service)

        XCTAssertEqual(viewModel.context.viewState.effectiveChatTheme, defaultTheme)
    }

    func testAChatPhotoFollowsTheMediaSettingOnlyInPublicChats() {
        let photo = ChatTheme(wallpaper: .photo(.mock), bubble: .pink)
        let defaultTheme = ChatTheme(wallpaper: .preset(.aurora), bubble: .green)
        let service = ChatBackgroundServiceMock(.init(theme: photo, defaultTheme: defaultTheme))

        let privateChat = makeTimelineViewModel(timelineController: MockTimelineController(timelineItems: []), service: service, joinRule: .invite)
        var state = privateChat.context.viewState
        XCTAssertTrue(state.isPrivateRoom)
        state.hideTimelineMedia = true
        XCTAssertEqual(state.effectiveChatTheme, photo)

        let publicChat = makeTimelineViewModel(timelineController: MockTimelineController(timelineItems: []), service: service, joinRule: .public)
        state = publicChat.context.viewState
        XCTAssertFalse(state.isPrivateRoom)
        XCTAssertEqual(state.effectiveChatTheme, photo)
        state.hideTimelineMedia = true
        XCTAssertEqual(state.effectiveChatTheme, defaultTheme)
    }

    func testThreadsKeepTheDefaultCanvas() {
        let service = ChatBackgroundServiceMock(.init(theme: ChatTheme(wallpaper: .preset(.night)), defaultTheme: ChatTheme(wallpaper: .preset(.aurora))))
        let viewModel = makeTimelineViewModel(timelineController: MockTimelineController(timelineKind: .thread(rootEventID: "$root"), timelineItems: []),
                                              service: service)
        XCTAssertEqual(viewModel.context.viewState.effectiveChatTheme, .stock)
        XCTAssertFalse(service.themePublisherRoomIDCalled)
    }

    private func noticeItem(eventID: String, timestamp: UInt64, background: ChatBackground) -> StateRoomTimelineItem {
        StateRoomTimelineItem(id: .event(uniqueID: .init(eventID), eventOrTransactionID: .eventID(eventID)),
                              body: "Bob changed the chat theme",
                              timestamp: .mock,
                              isOutgoing: false,
                              isEditable: false,
                              canBeRepliedTo: false,
                              sender: .init(id: otherUserID),
                              chatBackgroundEvent: .init(eventID: eventID, timestamp: timestamp, contentJSON: ChatTheme(wallpaper: background).contentJSON))
    }

    private func makeTimelineViewModel(timelineController: MockTimelineController,
                                       service: ChatBackgroundServiceMock,
                                       joinRule: JoinRule = .invite) -> TimelineViewModel {
        TimelineViewModel(roomProxy: JoinedRoomProxyMock(.init(id: "!room:gua.global", name: "Room", joinRule: joinRule)),
                          timelineController: timelineController,
                          userSession: UserSessionMock(.init(chatBackgroundService: service)),
                          mediaPlayerProvider: MediaPlayerProviderMock(),
                          userIndicatorController: UserIndicatorControllerMock(),
                          appMediator: AppMediatorMock.default,
                          appSettings: ServiceLocator.shared.settings,
                          analyticsService: ServiceLocator.shared.analytics,
                          emojiProvider: EmojiProvider(appSettings: ServiceLocator.shared.settings),
                          linkMetadataProvider: LinkMetadataProvider(),
                          timelineControllerFactory: TimelineControllerFactoryMock(.init()))
    }
}
