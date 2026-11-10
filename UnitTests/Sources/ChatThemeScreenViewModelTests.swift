//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import Foundation
import MatrixRustSDK
import Testing
import UIKit

@MainActor
final class ChatThemeScreenViewModelTests {
    private let ocean = ChatTheme(wallpaper: .preset(.ocean), bubble: .teal)
    private let aurora = ChatTheme(wallpaper: .preset(.aurora), bubble: .green)
    
    private var roomProxy: JoinedRoomProxyMock!
    private var clientProxy: ClientProxyMock!
    private var service: ChatBackgroundServiceMock!
    private var viewModel: ChatThemeScreenViewModel!
    
    private var context: ChatThemeScreenViewModel.Context {
        viewModel.context
    }
    
    @Test
    func chatModeShowsTheChatsThemeAndTheDefaultTile() {
        setUpViewModel(theme: ocean, defaultTheme: aurora)
        
        #expect(context.viewState.mode == .chat)
        #expect(context.viewState.current == ocean)
        #expect(context.viewState.firstTileTheme == aurora)
        #expect(context.viewState.firstTileName == UntranslatedL10n.guaChatBackgroundValueDefault)
        #expect(context.viewState.setThemeTitle == UntranslatedL10n.guaChatThemeActionSetTheme)
        #expect(context.viewState.note == UntranslatedL10n.guaChatThemeSharedNote)
        #expect(!context.viewState.current.isStock)
        #expect(context.viewState.sections.map(\.id) == [.featured, .colours, .gradients])
    }
    
    @Test
    func defaultModeShowsTheDefaultAndTheClassicTile() {
        setUpViewModel(mode: .defaultTheme, defaultTheme: aurora)
        
        #expect(context.viewState.mode == .defaultTheme)
        #expect(context.viewState.current == aurora)
        #expect(context.viewState.firstTileTheme == .stock)
        #expect(context.viewState.firstTileName == UntranslatedL10n.guaChatThemeClassic)
        #expect(context.viewState.setThemeTitle == UntranslatedL10n.guaChatThemeActionSetDefault)
        #expect(context.viewState.note == UntranslatedL10n.guaChatThemeDefaultNote)
        #expect(context.viewState.canChange)
    }
    
    @Test
    func choosingATileOpensThePreviewAndSavesNothing() {
        setUpViewModel(theme: ocean)
        
        context.send(viewAction: .selectTheme(aurora))
        
        #expect(context.viewState.bindings.themePreview?.theme == aurora)
        #expect(context.viewState.bindings.themePreview?.shownTheme == aurora)
        #expect(context.viewState.canSave(aurora))
        #expect(!service.setRoomProxyCalled)
        
        context.send(viewAction: .cancelPreview)
        
        #expect(context.viewState.bindings.themePreview == nil)
        #expect(!service.setRoomProxyCalled)
        #expect(context.viewState.current == ocean)
    }
    
    @Test
    func savingThePreviewSetsTheChatTheme() async throws {
        setUpViewModel(theme: ocean)
        
        context.send(viewAction: .selectTheme(aurora))
        context.send(viewAction: .setPreviewColorScheme(.dark))
        #expect(context.viewState.bindings.themePreview?.previewColorScheme == .dark)
        
        let closed = deferFulfillment(context.observe(\.viewState.bindings.themePreview)) { $0 == nil }
        context.send(viewAction: .savePreview)
        try await closed.fulfill()
        
        #expect(service.setRoomProxyReceivedArguments?.theme == aurora)
        #expect(context.viewState.current == aurora)
        #expect(!service.setDefaultThemeCalled)
    }
    
    @Test
    func theCurrentThemeCannotBeSetAgain() {
        setUpViewModel(theme: ocean)
        
        context.send(viewAction: .selectTheme(ocean))
        
        #expect(!(context.viewState.canSave(ocean)))
    }
    
    @Test
    func defaultTilePreviewsTheDefaultAndRemovesTheChatTheme() async throws {
        setUpViewModel(theme: ocean, defaultTheme: aurora)
        
        context.send(viewAction: .selectFirstTile)
        #expect(context.viewState.bindings.themePreview?.shownTheme == aurora)
        #expect(context.viewState.bindings.themePreview?.theme == .stock)
        
        let closed = deferFulfillment(context.observe(\.viewState.bindings.themePreview)) { $0 == nil }
        context.send(viewAction: .savePreview)
        try await closed.fulfill()
        
        #expect(service.setRoomProxyReceivedArguments?.theme == .stock)
        #expect(service.setRoomProxyReceivedArguments?.theme.contentJSON == "{}")
        #expect(context.viewState.current.isStock)
    }
    
    @Test
    func classicTileClearsTheDefault() async throws {
        setUpViewModel(mode: .defaultTheme, defaultTheme: aurora)
        
        context.send(viewAction: .selectFirstTile)
        #expect(context.viewState.bindings.themePreview?.shownTheme == .stock)
        
        let closed = deferFulfillment(context.observe(\.viewState.bindings.themePreview)) { $0 == nil }
        context.send(viewAction: .savePreview)
        try await closed.fulfill()
        
        #expect(service.setDefaultThemeReceivedTheme == .stock)
        #expect(!service.setRoomProxyCalled)
    }
    
    @Test
    func defaultModeSavesToTheDefault() async throws {
        setUpViewModel(mode: .defaultTheme, defaultTheme: aurora)
        
        context.send(viewAction: .selectTheme(ocean))
        let closed = deferFulfillment(context.observe(\.viewState.bindings.themePreview)) { $0 == nil }
        context.send(viewAction: .savePreview)
        try await closed.fulfill()
        
        #expect(service.setDefaultThemeReceivedTheme == ocean)
        #expect(context.viewState.current == ocean)
        #expect(!service.setRoomProxyCalled)
    }
    
    @Test
    func bubblePickerKeepsTheWallpaper() async throws {
        setUpViewModel(theme: ocean)
        
        context.send(viewAction: .presentBubblePicker)
        #expect(context.viewState.bindings.bubbleChoice == .teal)
        #expect(!(context.viewState.canSave(ChatTheme(wallpaper: ocean.wallpaper, bubble: .teal))))
        
        context.send(viewAction: .chooseBubble(.purple))
        let closed = deferFulfillment(context.observe(\.viewState.bindings.bubbleChoice)) { $0 == nil }
        context.send(viewAction: .setBubble)
        try await closed.fulfill()
        
        #expect(service.setRoomProxyReceivedArguments?.theme == ChatTheme(wallpaper: .preset(.ocean), bubble: .purple))
    }
    
    @Test
    func standardBubbleWithoutAWallpaperRemovesTheTheme() async throws {
        setUpViewModel(theme: ChatTheme(wallpaper: .none, bubble: .yellow))
        
        context.send(viewAction: .presentBubblePicker)
        context.send(viewAction: .chooseBubble(.standard))
        let closed = deferFulfillment(context.observe(\.viewState.bindings.bubbleChoice)) { $0 == nil }
        context.send(viewAction: .setBubble)
        try await closed.fulfill()
        
        #expect(service.setRoomProxyReceivedArguments?.theme.contentJSON == "{}")
    }
    
    @Test
    func wallpaperPickerKeepsTheBubble() async throws {
        setUpViewModel(theme: ocean)
        
        context.send(viewAction: .presentWallpaperPicker)
        context.send(viewAction: .selectWallpaper(.preset(.dawn)))
        #expect(context.viewState.bindings.wallpaperPreview?.theme == ChatTheme(wallpaper: .preset(.dawn), bubble: .teal))
        #expect(!service.setRoomProxyCalled)
        
        let closed = deferFulfillment(context.observe(\.viewState.bindings.isWallpaperPickerPresented)) { !$0 }
        context.send(viewAction: .savePreview)
        try await closed.fulfill()
        
        #expect(service.setRoomProxyReceivedArguments?.theme == ChatTheme(wallpaper: .preset(.dawn), bubble: .teal))
        #expect(context.viewState.bindings.wallpaperPreview == nil)
    }
    
    @Test
    func noWallpaperKeepsTheBubble() async throws {
        setUpViewModel(theme: ocean)
        
        context.send(viewAction: .presentWallpaperPicker)
        context.send(viewAction: .selectWallpaper(.none))
        let closed = deferFulfillment(context.observe(\.viewState.bindings.isWallpaperPickerPresented)) { !$0 }
        context.send(viewAction: .savePreview)
        try await closed.fulfill()
        
        #expect(service.setRoomProxyReceivedArguments?.theme.contentJSON == #"{"bubble":"teal","kind":"none","v":1}"#)
    }
    
    @Test
    func aChatFollowingTheDefaultStartsThePickersFromIt() async throws {
        setUpViewModel(theme: .stock, defaultTheme: aurora)
        
        #expect(context.viewState.baseTheme == aurora)
        #expect(context.viewState.shownWallpaper == aurora.wallpaper)
        
        context.send(viewAction: .presentWallpaperPicker)
        context.send(viewAction: .selectWallpaper(.preset(.dawn)))
        #expect(context.viewState.bindings.wallpaperPreview?.theme == ChatTheme(wallpaper: .preset(.dawn), bubble: .green))
        context.send(viewAction: .cancelPreview)
        context.send(viewAction: .presentBubblePicker)
        #expect(context.viewState.bindings.bubbleChoice == .green)
        #expect(!(context.viewState.canSavePickerChoice(aurora)))
        context.send(viewAction: .setBubble)
        #expect(!service.setRoomProxyCalled)
        
        context.send(viewAction: .chooseBubble(.blue))
        let closed = deferFulfillment(context.observe(\.viewState.bindings.bubbleChoice)) { $0 == nil }
        context.send(viewAction: .setBubble)
        try await closed.fulfill()
        
        #expect(service.setRoomProxyReceivedArguments?.theme == ChatTheme(wallpaper: .preset(.aurora), bubble: .blue))
    }
    
    @Test
    func keepingWhatAPickerStartsFromSendsNothing() throws {
        setUpViewModel(theme: .stock, defaultTheme: aurora)
        
        context.send(viewAction: .presentWallpaperPicker)
        context.send(viewAction: .selectWallpaper(.preset(.aurora)))
        let draft = try #require(context.viewState.bindings.wallpaperPreview)
        #expect(draft.theme == aurora)
        #expect(!(context.viewState.canSave(draft)))
        context.send(viewAction: .savePreview)
        
        context.send(viewAction: .selectTheme(aurora))
        #expect(try context.viewState.canSave(#require(context.viewState.bindings.themePreview)))
        
        #expect(!service.setRoomProxyCalled)
    }
    
    @Test
    func standardBubbleOnAChatWithoutAThemeSendsNothing() {
        setUpViewModel(theme: .stock, defaultTheme: ChatTheme(wallpaper: .photo(.mock), bubble: .blue))
        
        context.send(viewAction: .presentBubblePicker)
        context.send(viewAction: .chooseBubble(.standard))
        #expect(!(context.viewState.canSavePickerChoice(.stock)))
        context.send(viewAction: .setBubble)
        
        #expect(!service.setRoomProxyCalled)
        #expect(context.viewState.bindings.bubbleChoice == .standard)
    }
    
    @Test
    func theDefaultPhotoNeverGoesIntoAChat() async throws {
        setUpViewModel(theme: .stock, defaultTheme: ChatTheme(wallpaper: .photo(.mock), bubble: .pink))
        
        #expect(context.viewState.baseTheme == ChatTheme(wallpaper: .none, bubble: .pink))
        
        context.send(viewAction: .presentBubblePicker)
        context.send(viewAction: .chooseBubble(.blue))
        let closed = deferFulfillment(context.observe(\.viewState.bindings.bubbleChoice)) { $0 == nil }
        context.send(viewAction: .setBubble)
        try await closed.fulfill()
        
        #expect(service.setRoomProxyReceivedArguments?.theme.contentJSON == #"{"bubble":"blue","kind":"none","v":1}"#)
    }
    
    @Test
    func noWallpaperThatRemovesTheThemePreviewsTheDefault() {
        let dusk = ChatTheme(wallpaper: .preset(.dusk), bubble: .orange)
        setUpViewModel(theme: ChatTheme(wallpaper: .preset(.aurora)), defaultTheme: dusk)
        
        context.send(viewAction: .presentWallpaperPicker)
        context.send(viewAction: .selectWallpaper(.none))
        
        #expect(context.viewState.bindings.wallpaperPreview?.theme == .stock)
        #expect(context.viewState.bindings.wallpaperPreview?.shownTheme == dusk)
    }
    
    @Test
    func standardBubbleThatRemovesTheThemePreviewsTheDefault() {
        let dusk = ChatTheme(wallpaper: .preset(.dusk), bubble: .orange)
        setUpViewModel(theme: ChatTheme(wallpaper: .none, bubble: .yellow), defaultTheme: dusk)
        
        #expect(context.viewState.shownTheme(saving: ChatTheme(wallpaper: .none, bubble: .standard)) == dusk)
        #expect(context.viewState.shownTheme(saving: ChatTheme(wallpaper: .none, bubble: .blue)) == ChatTheme(wallpaper: .none, bubble: .blue))
        
        setUpViewModel(mode: .defaultTheme, defaultTheme: ChatTheme(wallpaper: .none, bubble: .yellow))
        #expect(context.viewState.shownTheme(saving: .stock) == .stock)
    }
    
    @Test
    func cancellingTheWallpaperPreviewReturnsToThePicker() {
        setUpViewModel(theme: ocean)
        
        context.send(viewAction: .presentWallpaperPicker)
        context.send(viewAction: .selectWallpaper(.preset(.citrus)))
        context.send(viewAction: .cancelPreview)
        
        #expect(context.viewState.bindings.wallpaperPreview == nil)
        #expect(context.viewState.bindings.isWallpaperPickerPresented)
        #expect(!service.setRoomProxyCalled)
    }
    
    @Test
    func withoutPermissionNothingCanBeSaved() {
        setUpViewModel(theme: ocean, canChange: false)
        
        #expect(!context.viewState.canChange)
        #expect(!(context.viewState.canSave(aurora)))
    }
    
    @Test
    func aChatPhotoIsHiddenOnlyWhereTheChatHidesIt() {
        setUpViewModel(theme: ChatTheme(wallpaper: .photo(.mock)), joinRule: .public, timelineMediaVisibility: .privateOnly)
        #expect(context.viewState.isPhotoHidden)
        #expect(context.viewState.shownWallpaper == .none)
        
        setUpViewModel(theme: ChatTheme(wallpaper: .photo(.mock)), joinRule: .invite, timelineMediaVisibility: .never)
        #expect(!context.viewState.isPhotoHidden)
        #expect(context.viewState.shownWallpaper == .photo(.mock))
        
        setUpViewModel(mode: .defaultTheme, defaultTheme: ChatTheme(wallpaper: .photo(.mock)), timelineMediaVisibility: .never)
        #expect(!context.viewState.isPhotoHidden)
    }
    
    @Test
    func photoIsPreparedUploadedAndSetWithTheBubble() async throws {
        setUpViewModel(theme: ocean)
        context.send(viewAction: .presentWallpaperPicker)
        
        let prepared = deferFulfillment(context.observe(\.viewState.bindings.photoDraft)) { $0 != nil }
        context.send(viewAction: .photoPicked { Self.photoData() })
        try await prepared.fulfill()
        
        let draft = try #require(context.viewState.bindings.photoDraft)
        #expect(draft.dim == ChatBackground.Photo.defaultDim)
        #expect(draft.upload.width == 2048)
        
        context.send(viewAction: .setPreviewColorScheme(.light))
        #expect(context.viewState.bindings.photoDraft?.previewColorScheme == .light)
        context.send(viewAction: .setPhotoDim(0.6))
        #expect(context.viewState.bindings.photoDraft?.dim == 0.6)
        #expect(context.viewState.bindings.photoDraft?.previewColorScheme == .dark)
        context.send(viewAction: .movePhoto(alignX: -1, alignY: 0.25))
        #expect(context.viewState.bindings.photoDraft?.alignX == 0)
        #expect(context.viewState.bindings.photoDraft?.alignY == 0.25)
        
        let closed = deferFulfillment(context.observe(\.viewState.bindings.isWallpaperPickerPresented)) { !$0 }
        context.send(viewAction: .setPhoto)
        try await closed.fulfill()
        
        #expect(clientProxy.uploadMediaDataMimeTypeReceivedArguments?.mimeType == "image/jpeg")
        #expect(clientProxy.uploadMediaDataMimeTypeReceivedArguments?.data == draft.upload.data)
        let theme = try #require(service.setRoomProxyReceivedArguments?.theme)
        let photo = try #require(theme.wallpaper.photo)
        #expect(theme.bubble == .teal)
        #expect(photo.url == "mxc://gua.global/uploaded")
        #expect(photo.mimetype == "image/jpeg")
        #expect(photo.width == 2048)
        #expect(photo.height == 1536)
        #expect(photo.size == draft.upload.data.count)
        #expect(photo.blurhash == draft.upload.blurhash)
        #expect(photo.dim == 0.6)
        #expect(photo.alignX == 0)
        #expect(photo.alignY == 0.25)
        #expect(context.viewState.bindings.photoDraft == nil)
    }
    
    @Test
    func defaultPhotoIsSavedToTheDefault() async throws {
        setUpViewModel(mode: .defaultTheme, defaultTheme: aurora)
        
        let prepared = deferFulfillment(context.observe(\.viewState.bindings.photoDraft)) { $0 != nil }
        context.send(viewAction: .photoPicked { Self.photoData() })
        try await prepared.fulfill()
        
        let closed = deferFulfillment(context.observe(\.viewState.bindings.photoDraft)) { $0 == nil }
        context.send(viewAction: .setPhoto)
        try await closed.fulfill()
        
        #expect(service.setDefaultThemeReceivedTheme?.wallpaper.photo?.url == "mxc://gua.global/uploaded")
        #expect(service.setDefaultThemeReceivedTheme?.bubble == .green)
        #expect(!service.setRoomProxyCalled)
    }
    
    @Test
    func discardingThePhotoKeepsTheTheme() async throws {
        setUpViewModel(theme: ocean)
        
        let prepared = deferFulfillment(context.observe(\.viewState.bindings.photoDraft)) { $0 != nil }
        context.send(viewAction: .photoPicked { Self.photoData() })
        try await prepared.fulfill()
        context.send(viewAction: .discardPhoto)
        
        #expect(context.viewState.bindings.photoDraft == nil)
        #expect(!clientProxy.uploadMediaDataMimeTypeCalled)
        #expect(!service.setRoomProxyCalled)
    }
    
    @Test
    func photoOverTheUploadLimitIsRefused() async throws {
        setUpViewModel(theme: .stock, maxUploadSize: 1000)
        
        let alert = deferFulfillment(context.observe(\.viewState.bindings.alertInfo)) { $0 != nil }
        context.send(viewAction: .photoPicked { Self.photoData() })
        try await alert.fulfill()
        
        #expect(context.viewState.bindings.alertInfo?.id == .photoTooLarge)
        #expect(context.viewState.bindings.photoDraft == nil)
    }
    
    @Test
    func unreadablePhotoShowsTheError() async throws {
        setUpViewModel(theme: .stock)
        
        let alert = deferFulfillment(context.observe(\.viewState.bindings.alertInfo)) { $0 != nil }
        context.send(viewAction: .photoPicked { Data("not a photo".utf8) })
        try await alert.fulfill()
        
        #expect(context.viewState.bindings.alertInfo?.id == .failed)
    }
    
    @Test
    func uploadFailureShowsTheErrorAndKeepsThePhoto() async throws {
        setUpViewModel(theme: .stock)
        clientProxy.uploadMediaDataMimeTypeReturnValue = .failure(.sdkError(ClientProxyMockError.generic))
        
        let prepared = deferFulfillment(context.observe(\.viewState.bindings.photoDraft)) { $0 != nil }
        context.send(viewAction: .photoPicked { Self.photoData() })
        try await prepared.fulfill()
        
        let alert = deferFulfillment(context.observe(\.viewState.bindings.alertInfo)) { $0 != nil }
        context.send(viewAction: .setPhoto)
        try await alert.fulfill()
        
        #expect(context.viewState.bindings.alertInfo?.id == .failed)
        #expect(!service.setRoomProxyCalled)
        #expect(context.viewState.bindings.photoDraft != nil)
    }
    
    @Test
    func refusedChangeKeepsThePreviewAndRereadsPermissions() async throws {
        setUpViewModel(theme: .stock)
        service.setRoomProxyClosure = { _, _ in .failure(.sdkError(RoomProxyMockError.generic)) }
        (roomProxy.infoPublisher.value.powerLevels as? RoomPowerLevelsProxyMock)?.canOwnUserSendStateEventClosure = { _ in false }
        
        context.send(viewAction: .selectTheme(aurora))
        let permissions = deferFulfillment(context.observe(\.viewState.canChange)) { $0 == false }
        context.send(viewAction: .savePreview)
        try await permissions.fulfill()
        
        #expect(context.viewState.bindings.alertInfo?.id == .failed)
        #expect(context.viewState.bindings.themePreview != nil)
        #expect(context.viewState.current == .stock)
    }
    
    @Test
    func failedDefaultWriteShowsTheError() async throws {
        setUpViewModel(mode: .defaultTheme, defaultTheme: aurora)
        service.setDefaultThemeClosure = { _ in .failure(.forbiddenAccess) }
        
        context.send(viewAction: .selectTheme(ocean))
        let alert = deferFulfillment(context.observe(\.viewState.bindings.alertInfo)) { $0 != nil }
        context.send(viewAction: .savePreview)
        try await alert.fulfill()
        
        #expect(context.viewState.bindings.alertInfo?.id == .failed)
        #expect(context.viewState.canChange)
    }
    
    private enum Mode {
        case chat
        case defaultTheme
    }
    
    private func setUpViewModel(mode: Mode = .chat,
                                theme: ChatTheme = .stock,
                                defaultTheme: ChatTheme = .stock,
                                canChange: Bool = true,
                                joinRule: ElementX.JoinRule = .invite,
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
