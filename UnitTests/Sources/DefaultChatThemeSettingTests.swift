//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import Foundation
import Testing

@MainActor
final class DefaultChatThemeSettingTests {
    private let aurora = ChatTheme(wallpaper: .preset(.aurora), bubble: .green)
    private let ocean = ChatTheme(wallpaper: .preset(.ocean), bubble: .teal)
    private let dusk = ChatTheme(wallpaper: .preset(.dusk), bubble: .orange)
    
    private var clientProxy: ClientProxyMock!
    private var cache: InMemoryChatBackgroundCache!
    private var setting: DefaultChatThemeSetting!
    
    init() {
        clientProxy = ClientProxyMock(.init())
        cache = InMemoryChatBackgroundCache()
        setting = DefaultChatThemeSetting(clientProxy: clientProxy, cache: cache)
    }
    
    @Test
    func cachedThemeIsShownBeforeTheStoreIsRead() {
        cache.defaultTheme = aurora.contentJSON
        
        setting = DefaultChatThemeSetting(clientProxy: clientProxy, cache: cache)
        
        #expect(setting.themePublisher.value == aurora)
        #expect(!clientProxy.accountDataTypeCalled)
    }
    
    @Test
    func storedThemeIsReadAndCached() async {
        clientProxy.accountDataTypeReturnValue = .success(ocean.contentJSON)
        
        await setting.refresh()
        
        #expect(clientProxy.accountDataTypeReceivedType == "global.gua.chat_theme")
        #expect(setting.themePublisher.value == ocean)
        #expect(cache.defaultTheme == ocean.contentJSON)
    }
    
    @Test
    func emptyContentClearsTheDefault() async {
        cache.defaultTheme = aurora.contentJSON
        setting = DefaultChatThemeSetting(clientProxy: clientProxy, cache: cache)
        clientProxy.accountDataTypeReturnValue = .success("{}")
        
        await setting.refresh()
        
        #expect(setting.themePublisher.value == .stock)
        #expect(cache.defaultTheme == "{}")
    }
    
    @Test
    func nothingStoredOnlyClearsTheCachedThemeAfterASync() async {
        cache.defaultTheme = aurora.contentJSON
        setting = DefaultChatThemeSetting(clientProxy: clientProxy, cache: cache)
        clientProxy.accountDataTypeReturnValue = .success(nil)
        
        await setting.refresh()
        #expect(setting.themePublisher.value == aurora)
        
        await setting.refresh(afterSync: true)
        #expect(setting.themePublisher.value == .stock)
    }
    
    @Test
    func readFailureKeepsTheTheme() async {
        cache.defaultTheme = aurora.contentJSON
        setting = DefaultChatThemeSetting(clientProxy: clientProxy, cache: cache)
        clientProxy.accountDataTypeReturnValue = .failure(.forbiddenAccess)
        
        await setting.refresh(afterSync: true)
        
        #expect(setting.themePublisher.value == aurora)
        #expect(cache.savedDefaultThemes.isEmpty)
    }
    
    @Test
    func writeShowsTheThemeBeforeTheServerAnswers() async throws {
        let gate = AccountDataWriteGate()
        clientProxy.setAccountDataTypeContentClosure = { _, _ in await gate.write() }
        
        let write = Task { await setting.set(ocean) }
        await gate.waitForWriters(1)
        
        #expect(setting.themePublisher.value == ocean)
        #expect(cache.defaultTheme == ocean.contentJSON)
        #expect(clientProxy.setAccountDataTypeContentReceivedArguments?.type == "global.gua.chat_theme")
        #expect(clientProxy.setAccountDataTypeContentReceivedArguments?.content == #"{"bubble":"teal","kind":"preset","preset":"ocean","v":1}"#)
        
        gate.release()
        try await write.value.get()
        #expect(setting.themePublisher.value == ocean)
    }
    
    @Test
    func clearingWritesEmptyContentNeverADeletion() async throws {
        cache.defaultTheme = aurora.contentJSON
        setting = DefaultChatThemeSetting(clientProxy: clientProxy, cache: cache)
        
        try await setting.set(.stock).get()
        
        #expect(clientProxy.setAccountDataTypeContentReceivedArguments?.content == "{}")
        #expect(setting.themePublisher.value == .stock)
    }
    
    @Test
    func failedWritePutsThePreviousThemeBack() async {
        cache.defaultTheme = aurora.contentJSON
        setting = DefaultChatThemeSetting(clientProxy: clientProxy, cache: cache)
        clientProxy.setAccountDataTypeContentReturnValue = .failure(.forbiddenAccess)
        
        let result = await setting.set(ocean)
        
        #expect(result.isFailure)
        #expect(setting.themePublisher.value == aurora)
        #expect(cache.defaultTheme == aurora.contentJSON)
    }
    
    @Test
    func staleReadsDoNotUndoAWriteUntilItsEchoArrives() async {
        let gate = AccountDataWriteGate()
        clientProxy.setAccountDataTypeContentClosure = { _, _ in await gate.write() }
        clientProxy.accountDataTypeReturnValue = .success(aurora.contentJSON)
        
        let write = Task { await setting.set(ocean) }
        await gate.waitForWriters(1)
        
        await setting.refresh(afterSync: true)
        #expect(setting.themePublisher.value == ocean)
        
        gate.release()
        _ = await write.value
        
        await setting.refresh(afterSync: true)
        #expect(setting.themePublisher.value == ocean)
        
        clientProxy.accountDataTypeReturnValue = .success(ocean.contentJSON)
        await setting.refresh(afterSync: true)
        #expect(setting.themePublisher.value == ocean)
        
        clientProxy.accountDataTypeReturnValue = .success(dusk.contentJSON)
        await setting.refresh(afterSync: true)
        #expect(setting.themePublisher.value == dusk)
    }
    
    @Test
    func echoOfARoundedPhotoIsRecognised() async {
        var photo = ChatBackground.Photo.mock
        photo.alignX = 0.123456
        photo.dim = 0.15000000000000002
        let theme = ChatTheme(wallpaper: .photo(photo), bubble: .blue)
        
        _ = await setting.set(theme)
        #expect(setting.themePublisher.value == ChatTheme(contentJSON: theme.contentJSON))
        
        clientProxy.accountDataTypeReturnValue = .success(theme.contentJSON)
        await setting.refresh(afterSync: true)
        clientProxy.accountDataTypeReturnValue = .success(dusk.contentJSON)
        await setting.refresh(afterSync: true)
        
        #expect(setting.themePublisher.value == dusk)
    }
    
    @Test
    func newerThemeFromAnotherDeviceWinsOnceTheEchoTimesOut() async {
        setting = DefaultChatThemeSetting(clientProxy: clientProxy, cache: cache, echoTimeout: 0)
        
        _ = await setting.set(ocean)
        clientProxy.accountDataTypeReturnValue = .success(dusk.contentJSON)
        await setting.refresh(afterSync: true)
        
        #expect(setting.themePublisher.value == dusk)
    }
    
    @Test
    func confirmedWriteIsKeptWhileTheStoreHasNothingYet() async {
        setting = DefaultChatThemeSetting(clientProxy: clientProxy, cache: cache, echoTimeout: 0)
        clientProxy.accountDataTypeReturnValue = .success(nil)
        
        _ = await setting.set(ocean)
        await setting.refresh(afterSync: true)
        
        #expect(setting.themePublisher.value == ocean)
    }
    
    @Test
    func overlappingWritesEndOnTheLastChoice() async {
        let gate = AccountDataWriteGate()
        clientProxy.setAccountDataTypeContentClosure = { _, _ in await gate.write() }
        
        let first = Task { await setting.set(ocean) }
        await gate.waitForWriters(1)
        let second = Task { await setting.set(dusk) }
        await Task.yield()
        #expect(setting.themePublisher.value == dusk)
        
        gate.release(.failure(.forbiddenAccess))
        await gate.waitForWriters(1)
        gate.release()
        _ = await first.value
        _ = await second.value
        
        #expect(setting.themePublisher.value == dusk)
        #expect(clientProxy.setAccountDataTypeContentReceivedArguments?.content == dusk.contentJSON)
    }
    
    @Test
    func storeIsReadAtStartThenAtMostOncePerSyncInterval() async throws {
        let syncUpdates = PassthroughSubject<ClientProxyAction, Never>()
        clientProxy.actionsPublisher = syncUpdates.eraseToAnyPublisher()
        cache.defaultTheme = aurora.contentJSON
        setting = DefaultChatThemeSetting(clientProxy: clientProxy, cache: cache, syncThrottle: .milliseconds(500))
        clientProxy.accountDataTypeReturnValue = .success(nil)
        
        setting.start()
        try await waitUntil { self.clientProxy.accountDataTypeCallsCount == 1 }
        #expect(setting.themePublisher.value == aurora)
        
        for _ in 0..<10 {
            syncUpdates.send(.receivedSyncUpdate)
            syncUpdates.send(.receivedAuthError(isSoftLogout: true))
        }
        try await waitUntil { self.clientProxy.accountDataTypeCallsCount >= 2 && self.setting.themePublisher.value == .stock }
        
        try await Task.sleep(for: .milliseconds(600))
        #expect(clientProxy.accountDataTypeCallsCount == 2)
    }
    
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
