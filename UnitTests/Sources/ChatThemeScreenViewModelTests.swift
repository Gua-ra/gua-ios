//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import MatrixRustSDK
import UIKit
import XCTest

@MainActor
final class ChatThemeScreenViewModelTests: XCTestCase {
    private let ocean = ChatTheme(wallpaper: .preset(.ocean), bubble: .teal)
    private let aurora = ChatTheme(wallpaper: .preset(.aurora), bubble: .green)

    private var roomProxy: JoinedRoomProxyMock!
    private var clientProxy: ClientProxyMock!
    private var service: ChatBackgroundServiceMock!
    private var viewModel: ChatThemeScreenViewModel!

    private var context: ChatThemeScreenViewModel.Context {
        viewModel.context
    }

    func testChatModeShowsTheChatsThemeAndTheDefaultTile() {
        setUpViewModel(theme: ocean, defaultTheme: aurora)

        XCTAssertEqual(context.viewState.mode, .chat)
        XCTAssertEqual(context.viewState.current, ocean)
        XCTAssertEqual(context.viewState.firstTileTheme, aurora)
        XCTAssertEqual(context.viewState.firstTileName, UntranslatedL10n.guaChatBackgroundValueDefault)
        XCTAssertEqual(context.viewState.setThemeTitle, UntranslatedL10n.guaChatThemeActionSetTheme)
        XCTAssertEqual(context.viewState.note, UntranslatedL10n.guaChatThemeSharedNote)
        XCTAssertFalse(context.viewState.current.isStock)
        XCTAssertEqual(context.viewState.sections.map(\.id), [.featured, .colours, .gradients])
    }

    func testDefaultModeShowsTheDefaultAndTheClassicTile() {
        setUpViewModel(mode: .defaultTheme, defaultTheme: aurora)

        XCTAssertEqual(context.viewState.mode, .defaultTheme)
        XCTAssertEqual(context.viewState.current, aurora)
        XCTAssertEqual(context.viewState.firstTileTheme, .stock)
        XCTAssertEqual(context.viewState.firstTileName, UntranslatedL10n.guaChatThemeClassic)
        XCTAssertEqual(context.viewState.setThemeTitle, UntranslatedL10n.guaChatThemeActionSetDefault)
        XCTAssertEqual(context.viewState.note, UntranslatedL10n.guaChatThemeDefaultNote)
        XCTAssertTrue(context.viewState.canChange)
    }

    func testChoosingATileOpensThePreviewAndSavesNothing() {
        setUpViewModel(theme: ocean)

        context.send(viewAction: .selectTheme(aurora))

        XCTAssertEqual(context.viewState.bindings.themePreview?.theme, aurora)
        XCTAssertEqual(context.viewState.bindings.themePreview?.shownTheme, aurora)
        XCTAssertTrue(context.viewState.canSave(aurora))
        XCTAssertFalse(service.setRoomProxyCalled)

        context.send(viewAction: .cancelPreview)

        XCTAssertNil(context.viewState.bindings.themePreview)
        XCTAssertFalse(service.setRoomProxyCalled)
        XCTAssertEqual(context.viewState.current, ocean)
    }

    func testSavingThePreviewSetsTheChatTheme() async throws {
        setUpViewModel(theme: ocean)

        context.send(viewAction: .selectTheme(aurora))
        context.send(viewAction: .setPreviewColorScheme(.dark))
        XCTAssertEqual(context.viewState.bindings.themePreview?.previewColorScheme, .dark)

        let closed = deferFulfillment(context.observe(\.viewState.bindings.themePreview)) { $0 == nil }
        context.send(viewAction: .savePreview)
        try await closed.fulfill()

        XCTAssertEqual(service.setRoomProxyReceivedArguments?.theme, aurora)
        XCTAssertEqual(context.viewState.current, aurora)
        XCTAssertFalse(service.setDefaultThemeCalled)
    }

    func testTheCurrentThemeCannotBeSetAgain() {
        setUpViewModel(theme: ocean)

        context.send(viewAction: .selectTheme(ocean))

        XCTAssertFalse(context.viewState.canSave(ocean))
    }

    func testDefaultTilePreviewsTheDefaultAndRemovesTheChatTheme() async throws {
        setUpViewModel(theme: ocean, defaultTheme: aurora)

        context.send(viewAction: .selectFirstTile)
        XCTAssertEqual(context.viewState.bindings.themePreview?.shownTheme, aurora)
        XCTAssertEqual(context.viewState.bindings.themePreview?.theme, .stock)

        let closed = deferFulfillment(context.observe(\.viewState.bindings.themePreview)) { $0 == nil }
        context.send(viewAction: .savePreview)
        try await closed.fulfill()

        XCTAssertEqual(service.setRoomProxyReceivedArguments?.theme, .stock)
        XCTAssertEqual(service.setRoomProxyReceivedArguments?.theme.contentJSON, "{}")
        XCTAssertTrue(context.viewState.current.isStock)
    }

    func testClassicTileClearsTheDefault() async throws {
        setUpViewModel(mode: .defaultTheme, defaultTheme: aurora)

        context.send(viewAction: .selectFirstTile)
        XCTAssertEqual(context.viewState.bindings.themePreview?.shownTheme, .stock)

        let closed = deferFulfillment(context.observe(\.viewState.bindings.themePreview)) { $0 == nil }
        context.send(viewAction: .savePreview)
        try await closed.fulfill()

        XCTAssertEqual(service.setDefaultThemeReceivedTheme, .stock)
        XCTAssertFalse(service.setRoomProxyCalled)
    }

    func testDefaultModeSavesToTheDefault() async throws {
        setUpViewModel(mode: .defaultTheme, defaultTheme: aurora)

        context.send(viewAction: .selectTheme(ocean))
        let closed = deferFulfillment(context.observe(\.viewState.bindings.themePreview)) { $0 == nil }
        context.send(viewAction: .savePreview)
        try await closed.fulfill()

        XCTAssertEqual(service.setDefaultThemeReceivedTheme, ocean)
        XCTAssertEqual(context.viewState.current, ocean)
        XCTAssertFalse(service.setRoomProxyCalled)
    }

    func testBubblePickerKeepsTheWallpaper() async throws {
        setUpViewModel(theme: ocean)

        context.send(viewAction: .presentBubblePicker)
        XCTAssertEqual(context.viewState.bindings.bubbleChoice, .teal)
        XCTAssertFalse(context.viewState.canSave(ChatTheme(wallpaper: ocean.wallpaper, bubble: .teal)))

        context.send(viewAction: .chooseBubble(.purple))
        let closed = deferFulfillment(context.observe(\.viewState.bindings.bubbleChoice)) { $0 == nil }
        context.send(viewAction: .setBubble)
        try await closed.fulfill()

        XCTAssertEqual(service.setRoomProxyReceivedArguments?.theme, ChatTheme(wallpaper: .preset(.ocean), bubble: .purple))
    }

    func testStandardBubbleWithoutAWallpaperRemovesTheTheme() async throws {
        setUpViewModel(theme: ChatTheme(wallpaper: .none, bubble: .yellow))

        context.send(viewAction: .presentBubblePicker)
        context.send(viewAction: .chooseBubble(.standard))
        let closed = deferFulfillment(context.observe(\.viewState.bindings.bubbleChoice)) { $0 == nil }
        context.send(viewAction: .setBubble)
        try await closed.fulfill()

        XCTAssertEqual(service.setRoomProxyReceivedArguments?.theme.contentJSON, "{}")
    }

    func testWallpaperPickerKeepsTheBubble() async throws {
        setUpViewModel(theme: ocean)

        context.send(viewAction: .presentWallpaperPicker)
        context.send(viewAction: .selectWallpaper(.preset(.dawn)))
        XCTAssertEqual(context.viewState.bindings.wallpaperPreview?.theme, ChatTheme(wallpaper: .preset(.dawn), bubble: .teal))
        XCTAssertFalse(service.setRoomProxyCalled)

        let closed = deferFulfillment(context.observe(\.viewState.bindings.isWallpaperPickerPresented)) { !$0 }
        context.send(viewAction: .savePreview)
        try await closed.fulfill()

        XCTAssertEqual(service.setRoomProxyReceivedArguments?.theme, ChatTheme(wallpaper: .preset(.dawn), bubble: .teal))
        XCTAssertNil(context.viewState.bindings.wallpaperPreview)
    }

    func testNoWallpaperKeepsTheBubble() async throws {
        setUpViewModel(theme: ocean)

        context.send(viewAction: .presentWallpaperPicker)
        context.send(viewAction: .selectWallpaper(.none))
        let closed = deferFulfillment(context.observe(\.viewState.bindings.isWallpaperPickerPresented)) { !$0 }
        context.send(viewAction: .savePreview)
        try await closed.fulfill()

        XCTAssertEqual(service.setRoomProxyReceivedArguments?.theme.contentJSON, #"{"bubble":"teal","kind":"none","v":1}"#)
    }

    func testAChatFollowingTheDefaultStartsThePickersFromIt() async throws {
        setUpViewModel(theme: .stock, defaultTheme: aurora)

        XCTAssertEqual(context.viewState.baseTheme, aurora)
        XCTAssertEqual(context.viewState.shownWallpaper, aurora.wallpaper)

        context.send(viewAction: .presentWallpaperPicker)
        context.send(viewAction: .selectWallpaper(.preset(.dawn)))
        XCTAssertEqual(context.viewState.bindings.wallpaperPreview?.theme, ChatTheme(wallpaper: .preset(.dawn), bubble: .green))
        context.send(viewAction: .cancelPreview)
        context.send(viewAction: .presentBubblePicker)
        XCTAssertEqual(context.viewState.bindings.bubbleChoice, .green)
        XCTAssertFalse(context.viewState.canSavePickerChoice(aurora))
        context.send(viewAction: .setBubble)
        XCTAssertFalse(service.setRoomProxyCalled)

        context.send(viewAction: .chooseBubble(.blue))
        let closed = deferFulfillment(context.observe(\.viewState.bindings.bubbleChoice)) { $0 == nil }
        context.send(viewAction: .setBubble)
        try await closed.fulfill()

        XCTAssertEqual(service.setRoomProxyReceivedArguments?.theme, ChatTheme(wallpaper: .preset(.aurora), bubble: .blue))
    }

    func testKeepingWhatAPickerStartsFromSendsNothing() throws {
        setUpViewModel(theme: .stock, defaultTheme: aurora)

        context.send(viewAction: .presentWallpaperPicker)
        context.send(viewAction: .selectWallpaper(.preset(.aurora)))
        let draft = try XCTUnwrap(context.viewState.bindings.wallpaperPreview)
        XCTAssertEqual(draft.theme, aurora)
        XCTAssertFalse(context.viewState.canSave(draft))
        context.send(viewAction: .savePreview)

        context.send(viewAction: .selectTheme(aurora))
        XCTAssertTrue(try context.viewState.canSave(XCTUnwrap(context.viewState.bindings.themePreview)))

        XCTAssertFalse(service.setRoomProxyCalled)
    }

    func testStandardBubbleOnAChatWithoutAThemeSendsNothing() {
        setUpViewModel(theme: .stock, defaultTheme: ChatTheme(wallpaper: .photo(.mock), bubble: .blue))

        context.send(viewAction: .presentBubblePicker)
        context.send(viewAction: .chooseBubble(.standard))
        XCTAssertFalse(context.viewState.canSavePickerChoice(.stock))
        context.send(viewAction: .setBubble)

        XCTAssertFalse(service.setRoomProxyCalled)
        XCTAssertEqual(context.viewState.bindings.bubbleChoice, .standard)
    }

    func testTheDefaultPhotoNeverGoesIntoAChat() async throws {
        setUpViewModel(theme: .stock, defaultTheme: ChatTheme(wallpaper: .photo(.mock), bubble: .pink))

        XCTAssertEqual(context.viewState.baseTheme, ChatTheme(wallpaper: .none, bubble: .pink))

        context.send(viewAction: .presentBubblePicker)
        context.send(viewAction: .chooseBubble(.blue))
        let closed = deferFulfillment(context.observe(\.viewState.bindings.bubbleChoice)) { $0 == nil }
        context.send(viewAction: .setBubble)
        try await closed.fulfill()

        XCTAssertEqual(service.setRoomProxyReceivedArguments?.theme.contentJSON, #"{"bubble":"blue","kind":"none","v":1}"#)
    }

    func testNoWallpaperThatRemovesTheThemePreviewsTheDefault() {
        let dusk = ChatTheme(wallpaper: .preset(.dusk), bubble: .orange)
        setUpViewModel(theme: ChatTheme(wallpaper: .preset(.aurora)), defaultTheme: dusk)

        context.send(viewAction: .presentWallpaperPicker)
        context.send(viewAction: .selectWallpaper(.none))

        XCTAssertEqual(context.viewState.bindings.wallpaperPreview?.theme, .stock)
        XCTAssertEqual(context.viewState.bindings.wallpaperPreview?.shownTheme, dusk)
    }

    func testStandardBubbleThatRemovesTheThemePreviewsTheDefault() {
        let dusk = ChatTheme(wallpaper: .preset(.dusk), bubble: .orange)
        setUpViewModel(theme: ChatTheme(wallpaper: .none, bubble: .yellow), defaultTheme: dusk)

        XCTAssertEqual(context.viewState.shownTheme(saving: ChatTheme(wallpaper: .none, bubble: .standard)), dusk)
        XCTAssertEqual(context.viewState.shownTheme(saving: ChatTheme(wallpaper: .none, bubble: .blue)), ChatTheme(wallpaper: .none, bubble: .blue))

        setUpViewModel(mode: .defaultTheme, defaultTheme: ChatTheme(wallpaper: .none, bubble: .yellow))
        XCTAssertEqual(context.viewState.shownTheme(saving: .stock), .stock)
    }

    func testCancellingTheWallpaperPreviewReturnsToThePicker() {
        setUpViewModel(theme: ocean)

        context.send(viewAction: .presentWallpaperPicker)
        context.send(viewAction: .selectWallpaper(.preset(.citrus)))
        context.send(viewAction: .cancelPreview)

        XCTAssertNil(context.viewState.bindings.wallpaperPreview)
        XCTAssertTrue(context.viewState.bindings.isWallpaperPickerPresented)
        XCTAssertFalse(service.setRoomProxyCalled)
    }

    func testWithoutPermissionNothingCanBeSaved() {
        setUpViewModel(theme: ocean, canChange: false)

        XCTAssertFalse(context.viewState.canChange)
        XCTAssertFalse(context.viewState.canSave(aurora))
    }

    func testAChatPhotoIsHiddenOnlyWhereTheChatHidesIt() {
        setUpViewModel(theme: ChatTheme(wallpaper: .photo(.mock)), joinRule: .public, timelineMediaVisibility: .privateOnly)
        XCTAssertTrue(context.viewState.isPhotoHidden)
        XCTAssertEqual(context.viewState.shownWallpaper, .none)

        setUpViewModel(theme: ChatTheme(wallpaper: .photo(.mock)), joinRule: .invite, timelineMediaVisibility: .never)
        XCTAssertFalse(context.viewState.isPhotoHidden)
        XCTAssertEqual(context.viewState.shownWallpaper, .photo(.mock))

        setUpViewModel(mode: .defaultTheme, defaultTheme: ChatTheme(wallpaper: .photo(.mock)), timelineMediaVisibility: .never)
        XCTAssertFalse(context.viewState.isPhotoHidden)
    }

    func testPhotoIsPreparedUploadedAndSetWithTheBubble() async throws {
        setUpViewModel(theme: ocean)
        context.send(viewAction: .presentWallpaperPicker)

        let prepared = deferFulfillment(context.observe(\.viewState.bindings.photoDraft)) { $0 != nil }
        context.send(viewAction: .photoPicked { Self.photoData() })
        try await prepared.fulfill()

        let draft = try XCTUnwrap(context.viewState.bindings.photoDraft)
        XCTAssertEqual(draft.dim, ChatBackground.Photo.defaultDim)
        XCTAssertEqual(draft.upload.width, 2048)

        context.send(viewAction: .setPreviewColorScheme(.light))
        XCTAssertEqual(context.viewState.bindings.photoDraft?.previewColorScheme, .light)
        context.send(viewAction: .setPhotoDim(0.6))
        XCTAssertEqual(context.viewState.bindings.photoDraft?.dim, 0.6)
        XCTAssertEqual(context.viewState.bindings.photoDraft?.previewColorScheme, .dark)
        context.send(viewAction: .movePhoto(alignX: -1, alignY: 0.25))
        XCTAssertEqual(context.viewState.bindings.photoDraft?.alignX, 0)
        XCTAssertEqual(context.viewState.bindings.photoDraft?.alignY, 0.25)

        let closed = deferFulfillment(context.observe(\.viewState.bindings.isWallpaperPickerPresented)) { !$0 }
        context.send(viewAction: .setPhoto)
        try await closed.fulfill()

        XCTAssertEqual(clientProxy.uploadMediaDataMimeTypeReceivedArguments?.mimeType, "image/jpeg")
        XCTAssertEqual(clientProxy.uploadMediaDataMimeTypeReceivedArguments?.data, draft.upload.data)
        let theme = try XCTUnwrap(service.setRoomProxyReceivedArguments?.theme)
        let photo = try XCTUnwrap(theme.wallpaper.photo)
        XCTAssertEqual(theme.bubble, .teal)
        XCTAssertEqual(photo.url, "mxc://gua.global/uploaded")
        XCTAssertEqual(photo.mimetype, "image/jpeg")
        XCTAssertEqual(photo.width, 2048)
        XCTAssertEqual(photo.height, 1536)
        XCTAssertEqual(photo.size, draft.upload.data.count)
        XCTAssertEqual(photo.blurhash, draft.upload.blurhash)
        XCTAssertEqual(photo.dim, 0.6)
        XCTAssertEqual(photo.alignX, 0)
        XCTAssertEqual(photo.alignY, 0.25)
        XCTAssertNil(context.viewState.bindings.photoDraft)
    }

    func testDefaultPhotoIsSavedToTheDefault() async throws {
        setUpViewModel(mode: .defaultTheme, defaultTheme: aurora)

        let prepared = deferFulfillment(context.observe(\.viewState.bindings.photoDraft)) { $0 != nil }
        context.send(viewAction: .photoPicked { Self.photoData() })
        try await prepared.fulfill()

        let closed = deferFulfillment(context.observe(\.viewState.bindings.photoDraft)) { $0 == nil }
        context.send(viewAction: .setPhoto)
        try await closed.fulfill()

        XCTAssertEqual(service.setDefaultThemeReceivedTheme?.wallpaper.photo?.url, "mxc://gua.global/uploaded")
        XCTAssertEqual(service.setDefaultThemeReceivedTheme?.bubble, .green)
        XCTAssertFalse(service.setRoomProxyCalled)
    }

    func testDiscardingThePhotoKeepsTheTheme() async throws {
        setUpViewModel(theme: ocean)

        let prepared = deferFulfillment(context.observe(\.viewState.bindings.photoDraft)) { $0 != nil }
        context.send(viewAction: .photoPicked { Self.photoData() })
        try await prepared.fulfill()
        context.send(viewAction: .discardPhoto)

        XCTAssertNil(context.viewState.bindings.photoDraft)
        XCTAssertFalse(clientProxy.uploadMediaDataMimeTypeCalled)
        XCTAssertFalse(service.setRoomProxyCalled)
    }

    func testPhotoOverTheUploadLimitIsRefused() async throws {
        setUpViewModel(theme: .stock, maxUploadSize: 1000)

        let alert = deferFulfillment(context.observe(\.viewState.bindings.alertInfo)) { $0 != nil }
        context.send(viewAction: .photoPicked { Self.photoData() })
        try await alert.fulfill()

        XCTAssertEqual(context.viewState.bindings.alertInfo?.id, .photoTooLarge)
        XCTAssertNil(context.viewState.bindings.photoDraft)
    }

    func testUnreadablePhotoShowsTheError() async throws {
        setUpViewModel(theme: .stock)

        let alert = deferFulfillment(context.observe(\.viewState.bindings.alertInfo)) { $0 != nil }
        context.send(viewAction: .photoPicked { Data("not a photo".utf8) })
        try await alert.fulfill()

        XCTAssertEqual(context.viewState.bindings.alertInfo?.id, .failed)
    }

    func testUploadFailureShowsTheErrorAndKeepsThePhoto() async throws {
        setUpViewModel(theme: .stock)
        clientProxy.uploadMediaDataMimeTypeReturnValue = .failure(.sdkError(ClientProxyMockError.generic))

        let prepared = deferFulfillment(context.observe(\.viewState.bindings.photoDraft)) { $0 != nil }
        context.send(viewAction: .photoPicked { Self.photoData() })
        try await prepared.fulfill()

        let alert = deferFulfillment(context.observe(\.viewState.bindings.alertInfo)) { $0 != nil }
        context.send(viewAction: .setPhoto)
        try await alert.fulfill()

        XCTAssertEqual(context.viewState.bindings.alertInfo?.id, .failed)
        XCTAssertFalse(service.setRoomProxyCalled)
        XCTAssertNotNil(context.viewState.bindings.photoDraft)
    }

    func testRefusedChangeKeepsThePreviewAndRereadsPermissions() async throws {
        setUpViewModel(theme: .stock)
        service.setRoomProxyClosure = { _, _ in .failure(.sdkError(RoomProxyMockError.generic)) }
        roomProxy.powerLevelsReturnValue = .success(RoomPowerLevelsProxyMock(configuration: .init(canUserSendState: false)))

        context.send(viewAction: .selectTheme(aurora))
        let permissions = deferFulfillment(context.observe(\.viewState.canChange)) { $0 == false }
        context.send(viewAction: .savePreview)
        try await permissions.fulfill()

        XCTAssertEqual(context.viewState.bindings.alertInfo?.id, .failed)
        XCTAssertNotNil(context.viewState.bindings.themePreview)
        XCTAssertEqual(context.viewState.current, .stock)
    }

    func testFailedDefaultWriteShowsTheError() async throws {
        setUpViewModel(mode: .defaultTheme, defaultTheme: aurora)
        service.setDefaultThemeClosure = { _ in .failure(.forbiddenAccess) }

        context.send(viewAction: .selectTheme(ocean))
        let alert = deferFulfillment(context.observe(\.viewState.bindings.alertInfo)) { $0 != nil }
        context.send(viewAction: .savePreview)
        try await alert.fulfill()

        XCTAssertEqual(context.viewState.bindings.alertInfo?.id, .failed)
        XCTAssertTrue(context.viewState.canChange)
        XCTAssertFalse(roomProxy.powerLevelsCalled)
    }

    private enum Mode {
        case chat
        case defaultTheme
    }

    private func setUpViewModel(mode: Mode = .chat,
                                theme: ChatTheme = .stock,
                                defaultTheme: ChatTheme = .stock,
                                canChange: Bool = true,
                                joinRule: JoinRule = .invite,
                                maxUploadSize: UInt = 100 * 1024 * 1024,
                                timelineMediaVisibility: TimelineMediaVisibility = .always) {
        roomProxy = JoinedRoomProxyMock(.init(id: "!room:gua.global", members: [canChange ? .mockMeAdmin : .mockMe, .mockAlice], joinRule: joinRule))
        clientProxy = ClientProxyMock(.init(timelineMediaVisibility: timelineMediaVisibility, maxMediaUploadSize: maxUploadSize))
        clientProxy.uploadMediaDataMimeTypeReturnValue = .success("mxc://gua.global/uploaded")
        service = ChatBackgroundServiceMock(.init(theme: theme, defaultTheme: defaultTheme))
        viewModel = ChatThemeScreenViewModel(mode: mode == .chat ? .chat(roomProxy) : .defaultTheme,
                                             clientProxy: clientProxy,
                                             chatBackgroundService: service,
                                             userIndicatorController: UserIndicatorControllerMock(),
                                             mediaProvider: nil)
    }

    private nonisolated static func photoData() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 3000), format: format)
        return renderer.jpegData(withCompressionQuality: 0.8) { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 1000, y: 1000, width: 1500, height: 800))
        }
    }
}
