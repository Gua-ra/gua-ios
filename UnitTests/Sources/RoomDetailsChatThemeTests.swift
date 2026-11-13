//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import XCTest

@MainActor
final class RoomDetailsChatThemeTests: XCTestCase {
    override func setUp() {
        AppSettings.resetAllSettings()
    }

    override func tearDown() {
        AppSettings.resetAllSettings()
    }

    func testDetailsRowShowsTheThemeAndPermission() async throws {
        ServiceLocator.shared.settings.guaChatBackgroundsEnabled = true
        let theme = ChatTheme(wallpaper: .preset(.lavender), bubble: .purple)
        let service = ChatBackgroundServiceMock(.init(theme: theme))

        let admin = makeDetailsViewModel(members: [.mockMeAdmin, .mockAlice], service: service)
        XCTAssertEqual(admin.context.viewState.chatTheme, theme)
        XCTAssertTrue(admin.context.viewState.canChangeChatTheme)

        let presented = deferFulfillment(admin.actions) { $0 == .displayChatTheme }
        admin.context.send(viewAction: .processTapChatTheme)
        try await presented.fulfill()

        let member = makeDetailsViewModel(members: [.mockMe, .mockAlice], service: service)
        XCTAssertFalse(member.context.viewState.canChangeChatTheme)
    }

    func testDetailsRowIsHiddenBehindTheFlagAndInSpaces() {
        let theme = ChatTheme(wallpaper: .preset(.lavender))
        let service = ChatBackgroundServiceMock(.init(theme: theme))

        ServiceLocator.shared.settings.guaChatBackgroundsEnabled = false
        XCTAssertNil(makeDetailsViewModel(members: [.mockMeAdmin], service: service).context.viewState.chatTheme)

        ServiceLocator.shared.settings.guaChatBackgroundsEnabled = true
        XCTAssertNil(makeDetailsViewModel(members: [.mockMeAdmin], isSpace: true, service: service).context.viewState.chatTheme)
        XCTAssertEqual(makeDetailsViewModel(members: [.mockMeAdmin], service: service).context.viewState.chatTheme, theme)
    }

    func testRowValueNamesTheTheme() {
        XCTAssertEqual(ChatTheme.stock.displayName, UntranslatedL10n.guaChatBackgroundValueDefault)
        XCTAssertEqual(ChatTheme(wallpaper: .preset(.dawn), bubble: .blue).displayName, UntranslatedL10n.guaChatThemePresetDawn)
        XCTAssertEqual(ChatTheme(wallpaper: .photo(.mock), bubble: .pink).displayName, UntranslatedL10n.guaChatBackgroundValuePhoto)
        XCTAssertEqual(ChatTheme(wallpaper: .none, bubble: .yellow).displayName, UntranslatedL10n.guaChatThemeBubbleYellow)
    }

    private func makeDetailsViewModel(members: [RoomMemberProxyMock], isSpace: Bool = false, service: ChatBackgroundServiceMock) -> RoomDetailsScreenViewModel {
        RoomDetailsScreenViewModel(roomProxy: JoinedRoomProxyMock(.init(id: "!room:gua.global", name: "Room", isSpace: isSpace, members: members)),
                                   userSession: UserSessionMock(.init(chatBackgroundService: service)),
                                   analyticsService: ServiceLocator.shared.analytics,
                                   userIndicatorController: UserIndicatorControllerMock(),
                                   notificationSettingsProxy: NotificationSettingsProxyMock(with: .init()),
                                   attributedStringBuilder: AttributedStringBuilder(mentionBuilder: MentionBuilder()),
                                   appSettings: ServiceLocator.shared.settings)
    }
}
