//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import XCTest

@MainActor
final class RoomDetailsChatBackgroundTests: XCTestCase {
    override func setUp() {
        AppSettings.resetAllSettings()
    }

    override func tearDown() {
        AppSettings.resetAllSettings()
    }

    func testDetailsRowShowsTheBackgroundAndPermission() async throws {
        ServiceLocator.shared.settings.guaChatBackgroundsEnabled = true
        let service = ChatBackgroundServiceMock(.init(background: .preset(.lavender)))

        let admin = makeDetailsViewModel(members: [.mockMeAdmin, .mockAlice], service: service)
        XCTAssertEqual(admin.context.viewState.chatBackground, .preset(.lavender))
        XCTAssertTrue(admin.context.viewState.canChangeChatBackground)

        let presented = deferFulfillment(admin.actions) { $0 == .displayChatBackground }
        admin.context.send(viewAction: .processTapChatBackground)
        try await presented.fulfill()

        let member = makeDetailsViewModel(members: [.mockMe, .mockAlice], service: service)
        XCTAssertFalse(member.context.viewState.canChangeChatBackground)
        let notPresented = deferFailure(member.actions, timeout: 0.5) { $0 == .displayChatBackground }
        member.context.send(viewAction: .processTapChatBackground)
        try await notPresented.fulfill()
    }

    func testDetailsRowIsHiddenBehindTheFlagAndInSpaces() {
        let service = ChatBackgroundServiceMock(.init(background: .preset(.lavender)))

        ServiceLocator.shared.settings.guaChatBackgroundsEnabled = false
        XCTAssertNil(makeDetailsViewModel(members: [.mockMeAdmin], service: service).context.viewState.chatBackground)

        ServiceLocator.shared.settings.guaChatBackgroundsEnabled = true
        XCTAssertNil(makeDetailsViewModel(members: [.mockMeAdmin], isSpace: true, service: service).context.viewState.chatBackground)
        XCTAssertEqual(makeDetailsViewModel(members: [.mockMeAdmin], service: service).context.viewState.chatBackground, .preset(.lavender))
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
