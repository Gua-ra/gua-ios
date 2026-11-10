//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import MatrixRustSDK
import Testing

@MainActor
final class ChatBackgroundTimelineTests {
    private let otherUserID = "@bob:gua.global"
    
    @Test
    func mainTimelineReportsTheNewestChangeAndShowsTheTheme() async throws {
        let theme = ChatTheme(wallpaper: .preset(.night), bubble: .purple)
        let service = ChatBackgroundServiceMock(.init(theme: theme, defaultTheme: ChatTheme(wallpaper: .preset(.aurora))))
        let (refreshes, refreshContinuation) = AsyncStream<Void>.makeStream()
        service.refreshRoomIDClosure = { _ in refreshContinuation.yield() }
        let refreshed = deferFulfillment(refreshes) { _ in true }
        let older = noticeItem(eventID: "$older", timestamp: 100, background: .preset(.sky))
        let newer = noticeItem(eventID: "$newer", timestamp: 200, background: .preset(.night))
        let timelineController = TimelineControllerMock(.init(timelineItems: [newer, older]))
        
        let viewModel = makeTimelineViewModel(timelineController: timelineController, service: service)
        try await refreshed.fulfill()
        
        #expect(viewModel.context.viewState.chatTheme == theme)
        #expect(viewModel.context.viewState.effectiveChatTheme == theme)
        #expect(service.handleTimelineEventRoomIDEventIDTimestampContentJSONCallsCount == 1)
        #expect(service.handleTimelineEventRoomIDEventIDTimestampContentJSONReceivedArguments?.eventID == "$newer")
        #expect(service.handleTimelineEventRoomIDEventIDTimestampContentJSONReceivedArguments?.timestamp == 200)
        
        timelineController.callbacks.send(.updatedTimelineItems(timelineItems: [newer, older], isSwitchingTimelines: false))
        try await Task.sleep(for: .milliseconds(50))
        #expect(service.handleTimelineEventRoomIDEventIDTimestampContentJSONCallsCount == 1)
    }
    
    @Test
    func defaultThemeShowsInAChatWithoutATheme() {
        let defaultTheme = ChatTheme(wallpaper: .preset(.dusk), bubble: .orange)
        let service = ChatBackgroundServiceMock(.init(defaultTheme: defaultTheme))
        
        let viewModel = makeTimelineViewModel(timelineController: TimelineControllerMock(.init(timelineItems: [])), service: service)
        
        #expect(viewModel.context.viewState.effectiveChatTheme == defaultTheme)
    }
    
    @Test
    func aChatPhotoFollowsTheMediaSettingOnlyInPublicChats() {
        let photo = ChatTheme(wallpaper: .photo(.mock), bubble: .pink)
        let defaultTheme = ChatTheme(wallpaper: .preset(.aurora), bubble: .green)
        let service = ChatBackgroundServiceMock(.init(theme: photo, defaultTheme: defaultTheme))
        
        let privateChat = makeTimelineViewModel(timelineController: TimelineControllerMock(.init(timelineItems: [])), service: service, joinRule: .invite)
        var state = privateChat.context.viewState
        #expect(state.isPrivateRoom)
        state.hideTimelineMedia = true
        #expect(state.effectiveChatTheme == photo)
        
        let publicChat = makeTimelineViewModel(timelineController: TimelineControllerMock(.init(timelineItems: [])), service: service, joinRule: .public)
        state = publicChat.context.viewState
        #expect(!state.isPrivateRoom)
        #expect(state.effectiveChatTheme == photo)
        state.hideTimelineMedia = true
        #expect(state.effectiveChatTheme == defaultTheme)
    }
    
    @Test
    func threadsKeepTheDefaultCanvas() {
        let service = ChatBackgroundServiceMock(.init(theme: ChatTheme(wallpaper: .preset(.night)), defaultTheme: ChatTheme(wallpaper: .preset(.aurora))))
        let viewModel = makeTimelineViewModel(timelineController: TimelineControllerMock(.init(timelineKind: .thread(rootEventID: "$root"), timelineItems: [])),
                                              service: service)
        #expect(viewModel.context.viewState.effectiveChatTheme == .stock)
        #expect(!service.themePublisherRoomIDCalled)
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
    
    private func makeTimelineViewModel(timelineController: TimelineControllerMock,
                                       service: ChatBackgroundServiceMock,
                                       joinRule: ElementX.JoinRule = .invite) -> TimelineViewModel {
        TimelineViewModel(roomProxy: JoinedRoomProxyMock(.init(id: "!room:gua.global", name: "Room", joinRule: joinRule)),
                          timelineController: timelineController,
                          userSession: UserSessionMock(.init(chatBackgroundService: service)),
                          mediaPlayerProvider: MediaPlayerProviderMock(),
                          userIndicatorController: UserIndicatorControllerMock(),
                          appMediator: AppMediatorMock(.init()),
                          analyticsService: AnalyticsServiceMock(.init()),
                          emojiProvider: EmojiProvider(userSettings: .mock()),
                          linkMetadataProvider: LinkMetadataProvider(),
                          timelineControllerFactory: TimelineControllerFactoryMock(.init()))
    }
}
