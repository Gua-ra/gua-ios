//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
@testable import ElementX
import Foundation
import Testing

@MainActor
final class StickerLibrarySettingTests {
    private let cat = StickerImage(url: "mxc://gua.global/cat", body: "Cat", info: StickerImageInfo(width: 256, height: 256, mimetype: "image/png", size: 1000))
    private let dog = StickerImage(url: "mxc://gua.global/dog", body: "Dog", info: nil)
    private let now = Date(timeIntervalSince1970: 1_762_905_600)
    
    private var clientProxy: ClientProxyMock!
    private var cache: InMemoryAccountDataCache!
    private var setting: StickerLibrarySetting!
    
    init() {
        clientProxy = ClientProxyMock(.init())
        cache = InMemoryAccountDataCache()
        setting = StickerLibrarySetting(clientProxy: clientProxy, cache: cache)
    }
    
    @Test
    func cachedLibraryIsShownBeforeTheStoreIsRead() {
        cache.contents[StickerLibrary.accountDataType] = library(favourites: [cat]).contentJSON
        
        setting = StickerLibrarySetting(clientProxy: clientProxy, cache: cache)
        
        #expect(setting.libraryPublisher.value.favourites == [cat])
        #expect(!clientProxy.accountDataTypeCalled)
    }
    
    @Test
    func storedLibraryIsReadAndCached() async {
        let stored = library(favourites: [dog])
        clientProxy.accountDataTypeReturnValue = .success(stored.contentJSON)
        
        await setting.refresh()
        
        #expect(clientProxy.accountDataTypeReceivedType == "global.gua.stickers")
        #expect(setting.libraryPublisher.value.favourites == [dog])
        #expect(cache.contents[StickerLibrary.accountDataType] == stored.contentJSON)
    }
    
    @Test
    func nothingStoredOnlyClearsTheCachedLibraryAfterASync() async {
        cache.contents[StickerLibrary.accountDataType] = library(favourites: [cat]).contentJSON
        setting = StickerLibrarySetting(clientProxy: clientProxy, cache: cache)
        clientProxy.accountDataTypeReturnValue = .success(nil)
        
        await setting.refresh()
        #expect(setting.libraryPublisher.value.favourites == [cat])
        
        await setting.refresh(afterSync: true)
        #expect(setting.libraryPublisher.value.favourites.isEmpty)
    }
    
    @Test
    func addingShowsTheStickerBeforeTheServerAnswers() async throws {
        let gate = AccountDataWriteGate()
        clientProxy.setAccountDataTypeContentClosure = { _, _ in await gate.write() }
        
        let write = Task { await setting.add(cat, now: now) }
        await gate.waitForWriters(1)
        
        #expect(setting.libraryPublisher.value.images.map(\.image.url) == [cat.url])
        let content = try #require(JSONValue(jsonString: clientProxy.setAccountDataTypeContentReceivedArguments?.content))
        #expect(content.objectValue?["images"]?.objectValue?["smhv8h6o0"]?.objectValue?[StickerImage.addedKey] == .int(1_762_905_600_000))
        
        gate.release()
        let item = try await write.value.get()
        #expect(item.shortcode == "smhv8h6o0")
    }
    
    @Test
    func addingPastTheLimitIsRefusedWithoutAWrite() async {
        var full = StickerLibrary(contentJSON: nil)
        for index in 0..<StickerLibrary.maxImages {
            _ = try? full.add(StickerImage(url: "mxc://gua.global/\(index)", body: nil, info: nil), now: Int64(index))
        }
        cache.contents[StickerLibrary.accountDataType] = full.contentJSON
        setting = StickerLibrarySetting(clientProxy: clientProxy, cache: cache)
        
        let result = await setting.add(cat, now: now)
        
        guard case .failure(.limitReached) = result else {
            Issue.record("Expected the limit, got \(result)")
            return
        }
        #expect(!clientProxy.setAccountDataTypeContentCalled)
    }
    
    @Test
    func failedWritePutsThePreviousLibraryBack() async {
        cache.contents[StickerLibrary.accountDataType] = library(favourites: [dog]).contentJSON
        setting = StickerLibrarySetting(clientProxy: clientProxy, cache: cache)
        clientProxy.setAccountDataTypeContentReturnValue = .failure(.forbiddenAccess)
        
        let result = await setting.favourite(cat)
        
        guard case .failure(.writeFailed) = result else {
            Issue.record("Expected a failed write, got \(result)")
            return
        }
        #expect(setting.libraryPublisher.value.favourites == [dog])
        #expect(cache.contents[StickerLibrary.accountDataType] == library(favourites: [dog]).contentJSON)
    }
    
    @Test
    func staleReadsDoNotUndoAWriteUntilItsEchoArrives() async {
        let gate = AccountDataWriteGate()
        clientProxy.setAccountDataTypeContentClosure = { _, _ in await gate.write() }
        clientProxy.accountDataTypeReturnValue = .success(library(favourites: [dog]).contentJSON)
        
        let write = Task { await setting.favourite(cat) }
        await gate.waitForWriters(1)
        
        await setting.refresh(afterSync: true)
        #expect(setting.libraryPublisher.value.favourites == [cat])
        
        gate.release()
        _ = await write.value
        
        await setting.refresh(afterSync: true)
        #expect(setting.libraryPublisher.value.favourites == [cat])
        
        clientProxy.accountDataTypeReturnValue = .success(library(favourites: [cat]).contentJSON)
        await setting.refresh(afterSync: true)
        clientProxy.accountDataTypeReturnValue = .success(library(favourites: [dog, cat]).contentJSON)
        await setting.refresh(afterSync: true)
        #expect(setting.libraryPublisher.value.favourites == [dog, cat])
    }
    
    @Test
    func newerLibraryFromAnotherDeviceWinsOnceTheEchoTimesOut() async {
        setting = StickerLibrarySetting(clientProxy: clientProxy, cache: cache, echoTimeout: 0)
        
        _ = await setting.favourite(cat)
        clientProxy.accountDataTypeReturnValue = .success(library(favourites: [dog]).contentJSON)
        await setting.refresh(afterSync: true)
        
        #expect(setting.libraryPublisher.value.favourites == [dog])
    }
    
    @Test
    func operationsBuildOnTheOptimisticLibrary() async {
        let gate = AccountDataWriteGate()
        clientProxy.setAccountDataTypeContentClosure = { _, _ in await gate.write() }
        
        let first = Task { await setting.favourite(cat) }
        await gate.waitForWriters(1)
        let second = Task { await setting.favourite(dog) }
        await Task.yield()
        #expect(setting.libraryPublisher.value.favourites == [dog, cat])
        
        gate.release()
        await gate.waitForWriters(1)
        gate.release()
        _ = await first.value
        _ = await second.value
        
        #expect(clientProxy.setAccountDataTypeContentReceivedArguments?.content == library(favourites: [dog, cat]).contentJSON)
    }
    
    @Test
    func deleteAlsoUnfavourites() async throws {
        let added = try await setting.add(cat, now: now).get()
        _ = await setting.favourite(cat)
        
        _ = await setting.delete(shortcode: added.shortcode)
        
        #expect(setting.libraryPublisher.value.images.isEmpty)
        #expect(setting.libraryPublisher.value.favourites.isEmpty)
    }
    
    @Test
    func storeIsReadAtStartThenAtMostOncePerSyncInterval() async throws {
        let syncUpdates = PassthroughSubject<ClientProxyAction, Never>()
        clientProxy.actionsPublisher = syncUpdates.eraseToAnyPublisher()
        setting = StickerLibrarySetting(clientProxy: clientProxy, cache: cache, syncThrottle: .milliseconds(500))
        
        setting.start()
        try await waitUntil { self.clientProxy.accountDataTypeCallsCount == 1 }
        
        for _ in 0..<10 {
            syncUpdates.send(.receivedSyncUpdate)
            syncUpdates.send(.receivedAuthError(isSoftLogout: true))
        }
        try await waitUntil { self.clientProxy.accountDataTypeCallsCount >= 2 }
        
        try await Task.sleep(for: .milliseconds(600))
        #expect(clientProxy.accountDataTypeCallsCount == 2)
    }
    
    @Test
    func gifFavouritesAreWrittenNewestFirst() async throws {
        let setting = GifFavouritesSetting(clientProxy: clientProxy, cache: cache)
        
        try await setting.favourite(id: "hello-1", provider: "klipy").get()
        try await setting.favourite(id: "wave-2", provider: "klipy").get()
        
        #expect(clientProxy.setAccountDataTypeContentReceivedArguments?.type == "global.gua.gifs")
        #expect(clientProxy.setAccountDataTypeContentReceivedArguments?.content == #"{"favourites":[{"id":"wave-2","p":"klipy"},{"id":"hello-1","p":"klipy"}],"v":1}"#)
        #expect(setting.favouritesPublisher.value.ids(provider: "klipy") == ["wave-2", "hello-1"])
    }
    
    private func library(favourites: [StickerImage]) -> StickerLibrary {
        var library = StickerLibrary(contentJSON: nil)
        for image in favourites.reversed() {
            library.favourite(image)
        }
        return library
    }
    
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}

final class InMemoryAccountDataCache: AccountDataCacheProtocol {
    var contents: [String: String] = [:]
    
    func load(type: String) -> String? {
        contents[type]
    }
    
    func save(_ contentJSON: String, type: String) {
        contents[type] = contentJSON
    }
}
