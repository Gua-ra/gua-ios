//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import UIKit
import XCTest

@MainActor
final class ChatBackgroundScreenViewModelTests: XCTestCase {
    private var roomProxy: JoinedRoomProxyMock!
    private var clientProxy: ClientProxyMock!
    private var service: ChatBackgroundServiceMock!
    private var viewModel: ChatBackgroundScreenViewModel!

    private var context: ChatBackgroundScreenViewModel.Context {
        viewModel.context
    }

    func testSelectingAPresetEnablesSetAndAppliesIt() async throws {
        setUpViewModel(current: .preset(.aurora))
        XCTAssertFalse(context.viewState.canSet)
        XCTAssertTrue(context.viewState.canRemove)

        context.send(viewAction: .selectPreset(.sunset))
        XCTAssertEqual(context.viewState.selection, .preset(.sunset))
        XCTAssertTrue(context.viewState.canSet)

        let dismissed = deferFulfillment(viewModel.actionsPublisher) { $0 == .dismiss }
        context.send(viewAction: .apply)
        try await dismissed.fulfill()

        XCTAssertEqual(service.setRoomProxyReceivedArguments?.0, .preset(.sunset))
        XCTAssertEqual(context.viewState.current, .preset(.sunset))
    }

    func testSelectingTheCurrentPresetKeepsSetDisabled() {
        setUpViewModel(current: .preset(.aurora))
        context.send(viewAction: .selectPreset(.aurora))
        XCTAssertFalse(context.viewState.canSet)
    }

    func testRemoveSendsNoBackground() async throws {
        setUpViewModel(current: .preset(.mint))

        let dismissed = deferFulfillment(viewModel.actionsPublisher) { $0 == .dismiss }
        context.send(viewAction: .remove)
        try await dismissed.fulfill()

        XCTAssertEqual(service.setRoomProxyReceivedArguments?.0, ChatBackground.none)
    }

    func testRemoveIsUnavailableWithoutABackground() {
        setUpViewModel(current: .none)
        XCTAssertFalse(context.viewState.canRemove)

        context.send(viewAction: .remove)
        XCTAssertFalse(service.setRoomProxyCalled)
    }

    func testWithoutPermissionNothingChanges() async throws {
        setUpViewModel(current: .preset(.mint), canChange: false)
        XCTAssertFalse(context.viewState.canChange)

        context.send(viewAction: .selectPreset(.night))
        context.send(viewAction: .apply)
        context.send(viewAction: .remove)
        context.send(viewAction: .photoPicked { Self.photoData() })
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(context.viewState.selection, .preset(.mint))
        XCTAssertFalse(context.viewState.canSet)
        XCTAssertFalse(context.viewState.canRemove)
        XCTAssertFalse(service.setRoomProxyCalled)
        XCTAssertNil(context.viewState.bindings.photoDraft)
    }

    func testPhotoIsPreparedUploadedAndSet() async throws {
        setUpViewModel(current: .none)

        let prepared = deferFulfillment(context.observe(\.viewState.bindings.photoDraft)) { $0 != nil }
        context.send(viewAction: .photoPicked { Self.photoData() })
        try await prepared.fulfill()

        let draft = try XCTUnwrap(context.viewState.bindings.photoDraft)
        XCTAssertEqual(draft.dim, ChatBackground.Photo.defaultDim)
        XCTAssertEqual(draft.upload.width, 2048)

        context.send(viewAction: .setPreviewColorScheme(.light))
        XCTAssertEqual(context.viewState.bindings.photoDraft?.previewColorScheme, .light)
        context.send(viewAction: .setPhotoDim(3))
        XCTAssertEqual(context.viewState.bindings.photoDraft?.dim, ChatBackground.Photo.maxDim)
        XCTAssertEqual(context.viewState.bindings.photoDraft?.previewColorScheme, .dark, "Dim only shows in the dark preview")
        context.send(viewAction: .setPhotoDim(0.6))
        context.send(viewAction: .movePhoto(alignX: -1, alignY: 0.25))
        XCTAssertEqual(context.viewState.bindings.photoDraft?.alignX, 0)
        XCTAssertEqual(context.viewState.bindings.photoDraft?.alignY, 0.25)

        let dismissed = deferFulfillment(viewModel.actionsPublisher) { $0 == .dismiss }
        context.send(viewAction: .apply)
        try await dismissed.fulfill()

        XCTAssertEqual(clientProxy.uploadMediaDataMimeTypeReceivedArguments?.mimeType, "image/jpeg")
        XCTAssertEqual(clientProxy.uploadMediaDataMimeTypeReceivedArguments?.data, draft.upload.data)
        guard case .photo(let photo) = service.setRoomProxyReceivedArguments?.0 else {
            XCTFail("A photo should have been set")
            return
        }
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

    func testDiscardingThePhotoKeepsTheBackground() async throws {
        setUpViewModel(current: .preset(.sky))

        let prepared = deferFulfillment(context.observe(\.viewState.bindings.photoDraft)) { $0 != nil }
        context.send(viewAction: .photoPicked { Self.photoData() })
        try await prepared.fulfill()
        context.send(viewAction: .discardPhoto)

        XCTAssertNil(context.viewState.bindings.photoDraft)
        XCTAssertFalse(clientProxy.uploadMediaDataMimeTypeCalled)
        XCTAssertFalse(service.setRoomProxyCalled)
    }

    func testPhotoOverTheUploadLimitIsRefused() async throws {
        setUpViewModel(current: .none, maxUploadSize: 1000)

        let alert = deferFulfillment(context.observe(\.viewState.bindings.alertInfo)) { $0 != nil }
        context.send(viewAction: .photoPicked { Self.photoData() })
        try await alert.fulfill()

        XCTAssertEqual(context.viewState.bindings.alertInfo?.id, .photoTooLarge)
        XCTAssertNil(context.viewState.bindings.photoDraft)
    }

    func testUnreadablePhotoShowsTheError() async throws {
        setUpViewModel(current: .none)

        let alert = deferFulfillment(context.observe(\.viewState.bindings.alertInfo)) { $0 != nil }
        context.send(viewAction: .photoPicked { Data("not a photo".utf8) })
        try await alert.fulfill()

        XCTAssertEqual(context.viewState.bindings.alertInfo?.id, .failed)
    }

    func testUploadFailureShowsTheErrorAndSetsNothing() async throws {
        setUpViewModel(current: .none)
        clientProxy.uploadMediaDataMimeTypeReturnValue = .failure(.sdkError(RoomProxyMockError.generic))

        let prepared = deferFulfillment(context.observe(\.viewState.bindings.photoDraft)) { $0 != nil }
        context.send(viewAction: .photoPicked { Self.photoData() })
        try await prepared.fulfill()

        let alert = deferFulfillment(context.observe(\.viewState.bindings.alertInfo)) { $0 != nil }
        context.send(viewAction: .apply)
        try await alert.fulfill()

        XCTAssertEqual(context.viewState.bindings.alertInfo?.id, .failed)
        XCTAssertFalse(service.setRoomProxyCalled)
        XCTAssertNotNil(context.viewState.bindings.photoDraft)
    }

    func testRefusedChangeShowsTheErrorAndRereadsPermissions() async throws {
        setUpViewModel(current: .none)
        service.setRoomProxyClosure = { _, _ in .failure(.failedSending(.sdkError(RoomProxyMockError.generic))) }
        let powerLevels = RoomPowerLevelsProxyMock(configuration: .init(canUserSendState: false))
        roomProxy.powerLevelsReturnValue = .success(powerLevels)

        context.send(viewAction: .selectPreset(.ocean))
        let permissions = deferFulfillment(context.observe(\.viewState.canChange)) { $0 == false }
        context.send(viewAction: .apply)
        try await permissions.fulfill()

        XCTAssertEqual(context.viewState.bindings.alertInfo?.id, .failed)
        XCTAssertEqual(context.viewState.current, .none)
    }

    private func setUpViewModel(current: ChatBackground, canChange: Bool = true, maxUploadSize: UInt = 100 * 1024 * 1024) {
        roomProxy = JoinedRoomProxyMock(.init(id: "!room:gua.global", members: [canChange ? .mockMeAdmin : .mockMe, .mockAlice]))
        clientProxy = ClientProxyMock(.init(maxMediaUploadSize: maxUploadSize))
        clientProxy.uploadMediaDataMimeTypeReturnValue = .success("mxc://gua.global/uploaded")
        service = ChatBackgroundServiceMock(.init(background: current))
        viewModel = ChatBackgroundScreenViewModel(roomProxy: roomProxy,
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
