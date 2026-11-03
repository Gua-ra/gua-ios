//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import XCTest

@MainActor
final class ChatBackgroundTimelineTests: XCTestCase {
    private let otherUserID = "@bob:gua.global"

    func testMainTimelineReportsTheNewestChangeAndShowsTheBackground() async throws {
        let service = ChatBackgroundServiceMock(.init(background: .preset(.night)))
        let refreshed = expectation(description: "The server's state is read when the chat opens")
        service.refreshRoomIDClosure = { _ in refreshed.fulfill() }
        let older = noticeItem(eventID: "$older", timestamp: 100, background: .preset(.sky))
        let newer = noticeItem(eventID: "$newer", timestamp: 200, background: .preset(.night))
        let timelineController = MockTimelineController(timelineItems: [newer, older])

        let viewModel = makeTimelineViewModel(timelineController: timelineController, service: service)
        await fulfillment(of: [refreshed], timeout: 1)

        XCTAssertEqual(viewModel.context.viewState.chatBackground, .preset(.night))
        XCTAssertEqual(service.handleTimelineEventRoomIDEventIDTimestampContentJSONCallsCount, 1)
        XCTAssertEqual(service.handleTimelineEventRoomIDEventIDTimestampContentJSONReceivedArguments?.eventID, "$newer")
        XCTAssertEqual(service.handleTimelineEventRoomIDEventIDTimestampContentJSONReceivedArguments?.timestamp, 200)

        timelineController.callbacks.send(.updatedTimelineItems(timelineItems: [newer, older], isSwitchingTimelines: false))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(service.handleTimelineEventRoomIDEventIDTimestampContentJSONCallsCount, 1)
    }

    func testPhotoIsHiddenWhenTheChatHidesMedia() {
        let service = ChatBackgroundServiceMock(.init(background: .photo(.mock)))
        let viewModel = makeTimelineViewModel(timelineController: MockTimelineController(timelineItems: []), service: service)
        var state = viewModel.context.viewState
        XCTAssertEqual(state.visibleChatBackground, .photo(.mock))

        state.hideTimelineMedia = true
        XCTAssertEqual(state.visibleChatBackground, .none)

        state.chatBackground = .preset(.sand)
        XCTAssertEqual(state.visibleChatBackground, .preset(.sand))
    }

    func testThreadsKeepTheDefaultCanvas() {
        let service = ChatBackgroundServiceMock(.init(background: .preset(.night)))
        let viewModel = makeTimelineViewModel(timelineController: MockTimelineController(timelineKind: .thread(rootEventID: "$root"), timelineItems: []),
                                              service: service)
        XCTAssertEqual(viewModel.context.viewState.chatBackground, .none)
        XCTAssertFalse(service.backgroundPublisherRoomIDCalled)
    }

    private func noticeItem(eventID: String, timestamp: UInt64, background: ChatBackground) -> StateRoomTimelineItem {
        StateRoomTimelineItem(id: .event(uniqueID: .init(eventID), eventOrTransactionID: .eventID(eventID)),
                              body: "Bob changed the chat background",
                              timestamp: .mock,
                              isOutgoing: false,
                              isEditable: false,
                              canBeRepliedTo: false,
                              sender: .init(id: otherUserID),
                              chatBackgroundEvent: .init(eventID: eventID, timestamp: timestamp, contentJSON: background.contentJSON))
    }

    private func makeTimelineViewModel(timelineController: MockTimelineController, service: ChatBackgroundServiceMock) -> TimelineViewModel {
        TimelineViewModel(roomProxy: JoinedRoomProxyMock(.init(id: "!room:gua.global", name: "Room")),
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
