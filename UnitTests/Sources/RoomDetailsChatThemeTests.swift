//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

@MainActor
struct RoomDetailsChatThemeTests {
    private let userSettings = UserSettings.mock()
    
    @Test
    func detailsRowShowsTheThemeAndPermission() async throws {
        userSettings.app.guaChatBackgroundsEnabled = true
        let theme = ChatTheme(wallpaper: .preset(.lavender), bubble: .purple)
        let service = ChatBackgroundServiceMock(.init(theme: theme))
        
        let admin = makeDetailsViewModel(members: [.mockMeAdmin, .mockAlice], service: service)
        #expect(admin.context.viewState.chatTheme == theme)
        #expect(admin.context.viewState.canChangeChatTheme)
        
        let presented = deferFulfillment(admin.actions) { $0 == .displayChatTheme }
        admin.context.send(viewAction: .processTapChatTheme)
        try await presented.fulfill()
        
        let member = makeDetailsViewModel(members: [.mockMe, .mockAlice], service: service)
        #expect(!member.context.viewState.canChangeChatTheme)
    }
    
    @Test
    func detailsRowIsHiddenBehindTheFlagAndInSpaces() {
        let theme = ChatTheme(wallpaper: .preset(.lavender))
        let service = ChatBackgroundServiceMock(.init(theme: theme))
        
        userSettings.app.guaChatBackgroundsEnabled = false
        #expect(makeDetailsViewModel(members: [.mockMeAdmin], service: service).context.viewState.chatTheme == nil)
        
        userSettings.app.guaChatBackgroundsEnabled = true
        #expect(makeDetailsViewModel(members: [.mockMeAdmin], isSpace: true, service: service).context.viewState.chatTheme == nil)
        #expect(makeDetailsViewModel(members: [.mockMeAdmin], service: service).context.viewState.chatTheme == theme)
    }
    
    @Test
    func rowValueNamesTheTheme() {
        #expect(ChatTheme.stock.displayName == UntranslatedL10n.guaChatBackgroundValueDefault)
        #expect(ChatTheme(wallpaper: .preset(.dawn), bubble: .blue).displayName == UntranslatedL10n.guaChatThemePresetDawn)
        #expect(ChatTheme(wallpaper: .photo(.mock), bubble: .pink).displayName == UntranslatedL10n.guaChatBackgroundValuePhoto)
        #expect(ChatTheme(wallpaper: .none, bubble: .yellow).displayName == UntranslatedL10n.guaChatThemeBubbleYellow)
    }
    
    private func makeDetailsViewModel(members: [RoomMemberProxyMock], isSpace: Bool = false, service: ChatBackgroundServiceMock) -> RoomDetailsScreenViewModel {
        RoomDetailsScreenViewModel(roomProxy: JoinedRoomProxyMock(.init(id: "!room:gua.global", name: "Room", isSpace: isSpace, members: members)),
                                   userSession: UserSessionMock(.init(userSettings: userSettings, chatBackgroundService: service)),
                                   analyticsService: AnalyticsServiceMock(.init()),
                                   userIndicatorController: UserIndicatorControllerMock(),
                                   notificationSettingsProxy: NotificationSettingsProxyMock(with: .init()),
                                   attributedStringBuilder: AttributedStringBuilder(mentionBuilder: MentionBuilder()))
    }
}
