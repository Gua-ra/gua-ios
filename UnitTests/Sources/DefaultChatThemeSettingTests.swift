//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import XCTest

@MainActor
final class DefaultChatThemeSettingTests: XCTestCase {
    private let aurora = ChatTheme(wallpaper: .preset(.aurora), bubble: .green)
    private let ocean = ChatTheme(wallpaper: .preset(.ocean), bubble: .teal)
    private let dusk = ChatTheme(wallpaper: .preset(.dusk), bubble: .orange)

    private var clientProxy: ClientProxyMock!
    private var cache: InMemoryChatBackgroundCache!
    private var setting: DefaultChatThemeSetting!

    override func setUp() {
        clientProxy = ClientProxyMock(.init())
        cache = InMemoryChatBackgroundCache()
        setting = DefaultChatThemeSetting(clientProxy: clientProxy, cache: cache)
    }

    func testCachedThemeIsShownBeforeTheStoreIsRead() {
        cache.defaultTheme = aurora.contentJSON

        setting = DefaultChatThemeSetting(clientProxy: clientProxy, cache: cache)

        XCTAssertEqual(setting.themePublisher.value, aurora)
        XCTAssertFalse(clientProxy.accountDataTypeCalled)
    }

    func testStoredThemeIsReadAndCached() async {
        clientProxy.accountDataTypeReturnValue = .success(ocean.contentJSON)

        await setting.refresh()

        XCTAssertEqual(clientProxy.accountDataTypeReceivedType, "global.gua.chat_theme")
        XCTAssertEqual(setting.themePublisher.value, ocean)
        XCTAssertEqual(cache.defaultTheme, ocean.contentJSON)
    }

    func testEmptyContentClearsTheDefault() async {
        cache.defaultTheme = aurora.contentJSON
        setting = DefaultChatThemeSetting(clientProxy: clientProxy, cache: cache)
        clientProxy.accountDataTypeReturnValue = .success("{}")

        await setting.refresh()

        XCTAssertEqual(setting.themePublisher.value, .stock)
        XCTAssertEqual(cache.defaultTheme, "{}")
    }

    func testNothingStoredOnlyClearsTheCachedThemeAfterASync() async {
        cache.defaultTheme = aurora.contentJSON
        setting = DefaultChatThemeSetting(clientProxy: clientProxy, cache: cache)
        clientProxy.accountDataTypeReturnValue = .success(nil)

        await setting.refresh()
        XCTAssertEqual(setting.themePublisher.value, aurora)

        await setting.refresh(afterSync: true)
        XCTAssertEqual(setting.themePublisher.value, .stock)
    }

    func testReadFailureKeepsTheTheme() async {
        cache.defaultTheme = aurora.contentJSON
        setting = DefaultChatThemeSetting(clientProxy: clientProxy, cache: cache)
        clientProxy.accountDataTypeReturnValue = .failure(.forbiddenAccess)

        await setting.refresh(afterSync: true)

        XCTAssertEqual(setting.themePublisher.value, aurora)
        XCTAssertTrue(cache.savedDefaultThemes.isEmpty)
    }

    func testWriteShowsTheThemeBeforeTheServerAnswers() async throws {
        let gate = AccountDataWriteGate()
        clientProxy.setAccountDataTypeContentClosure = { _, _ in await gate.write() }

        let write = Task { await setting.set(ocean) }
        await gate.waitForWriters(1)

        XCTAssertEqual(setting.themePublisher.value, ocean)
        XCTAssertEqual(cache.defaultTheme, ocean.contentJSON)
        XCTAssertEqual(clientProxy.setAccountDataTypeContentReceivedArguments?.type, "global.gua.chat_theme")
        XCTAssertEqual(clientProxy.setAccountDataTypeContentReceivedArguments?.content, #"{"bubble":"teal","kind":"preset","preset":"ocean","v":1}"#)

        gate.release()
        try await write.value.get()
        XCTAssertEqual(setting.themePublisher.value, ocean)
    }

    func testClearingWritesEmptyContentNeverADeletion() async throws {
        cache.defaultTheme = aurora.contentJSON
        setting = DefaultChatThemeSetting(clientProxy: clientProxy, cache: cache)

        try await setting.set(.stock).get()

        XCTAssertEqual(clientProxy.setAccountDataTypeContentReceivedArguments?.content, "{}")
        XCTAssertEqual(setting.themePublisher.value, .stock)
    }

    func testFailedWritePutsThePreviousThemeBack() async {
        cache.defaultTheme = aurora.contentJSON
        setting = DefaultChatThemeSetting(clientProxy: clientProxy, cache: cache)
        clientProxy.setAccountDataTypeContentReturnValue = .failure(.forbiddenAccess)

        let result = await setting.set(ocean)

        XCTAssertTrue(result.isFailure)
        XCTAssertEqual(setting.themePublisher.value, aurora)
        XCTAssertEqual(cache.defaultTheme, aurora.contentJSON)
    }

    func testStaleReadsDoNotUndoAWriteUntilItsEchoArrives() async {
        let gate = AccountDataWriteGate()
        clientProxy.setAccountDataTypeContentClosure = { _, _ in await gate.write() }
        clientProxy.accountDataTypeReturnValue = .success(aurora.contentJSON)

        let write = Task { await setting.set(ocean) }
        await gate.waitForWriters(1)

        await setting.refresh(afterSync: true)
        XCTAssertEqual(setting.themePublisher.value, ocean)

        gate.release()
        _ = await write.value

        await setting.refresh(afterSync: true)
        XCTAssertEqual(setting.themePublisher.value, ocean)

        clientProxy.accountDataTypeReturnValue = .success(ocean.contentJSON)
        await setting.refresh(afterSync: true)
        XCTAssertEqual(setting.themePublisher.value, ocean)

        clientProxy.accountDataTypeReturnValue = .success(dusk.contentJSON)
        await setting.refresh(afterSync: true)
        XCTAssertEqual(setting.themePublisher.value, dusk)
    }

    func testEchoOfARoundedPhotoIsRecognised() async {
        var photo = ChatBackground.Photo.mock
        photo.alignX = 0.123456
        photo.dim = 0.15000000000000002
        let theme = ChatTheme(wallpaper: .photo(photo), bubble: .blue)

        _ = await setting.set(theme)
        XCTAssertEqual(setting.themePublisher.value, ChatTheme(contentJSON: theme.contentJSON))

        clientProxy.accountDataTypeReturnValue = .success(theme.contentJSON)
        await setting.refresh(afterSync: true)
        clientProxy.accountDataTypeReturnValue = .success(dusk.contentJSON)
        await setting.refresh(afterSync: true)

        XCTAssertEqual(setting.themePublisher.value, dusk)
    }

    func testNewerThemeFromAnotherDeviceWinsOnceTheEchoTimesOut() async {
        setting = DefaultChatThemeSetting(clientProxy: clientProxy, cache: cache, echoTimeout: 0)

        _ = await setting.set(ocean)
        clientProxy.accountDataTypeReturnValue = .success(dusk.contentJSON)
        await setting.refresh(afterSync: true)

        XCTAssertEqual(setting.themePublisher.value, dusk)
    }

    func testConfirmedWriteIsKeptWhileTheStoreHasNothingYet() async {
        setting = DefaultChatThemeSetting(clientProxy: clientProxy, cache: cache, echoTimeout: 0)
        clientProxy.accountDataTypeReturnValue = .success(nil)

        _ = await setting.set(ocean)
        await setting.refresh(afterSync: true)

        XCTAssertEqual(setting.themePublisher.value, ocean)
    }

    func testOverlappingWritesEndOnTheLastChoice() async {
        let gate = AccountDataWriteGate()
        clientProxy.setAccountDataTypeContentClosure = { _, _ in await gate.write() }

        let first = Task { await setting.set(ocean) }
        await gate.waitForWriters(1)
        let second = Task { await setting.set(dusk) }
        await Task.yield()
        XCTAssertEqual(setting.themePublisher.value, dusk)

        gate.release(.failure(.forbiddenAccess))
        await gate.waitForWriters(1)
        gate.release()
        _ = await first.value
        _ = await second.value

        XCTAssertEqual(setting.themePublisher.value, dusk)
        XCTAssertEqual(clientProxy.setAccountDataTypeContentReceivedArguments?.content, dusk.contentJSON)
    }

    func testStoreIsReadAtStartThenAtMostOncePerSyncInterval() async throws {
        let syncUpdates = PassthroughSubject<ClientProxyAction, Never>()
        clientProxy.actionsPublisher = syncUpdates.eraseToAnyPublisher()
        cache.defaultTheme = aurora.contentJSON
        setting = DefaultChatThemeSetting(clientProxy: clientProxy, cache: cache, syncThrottle: .milliseconds(500))
        clientProxy.accountDataTypeReturnValue = .success(nil)

        setting.start()
        try await waitUntil { self.clientProxy.accountDataTypeCallsCount == 1 }
        XCTAssertEqual(setting.themePublisher.value, aurora)

        for _ in 0..<10 {
            syncUpdates.send(.receivedSyncUpdate)
            syncUpdates.send(.receivedAuthError(isSoftLogout: true))
        }
        try await waitUntil { self.clientProxy.accountDataTypeCallsCount >= 2 && self.setting.themePublisher.value == .stock }

        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(clientProxy.accountDataTypeCallsCount, 2)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }
}

@MainActor
private final class AccountDataWriteGate {
    private var waiting: [CheckedContinuation<Result<Void, ClientProxyError>, Never>] = []

    func write() async -> Result<Void, ClientProxyError> {
        await withCheckedContinuation { waiting.append($0) }
    }

    func waitForWriters(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 {
            if waiting.count >= count { return }
            await Task.yield()
        }
        XCTFail("Expected \(count) pending writes, found \(waiting.count)", file: file, line: line)
    }

    func release(_ result: Result<Void, ClientProxyError> = .success(()), file: StaticString = #filePath, line: UInt = #line) {
        guard !waiting.isEmpty else {
            XCTFail("No write is waiting to be released.", file: file, line: line)
            return
        }
        waiting.removeFirst().resume(returning: result)
    }
}
