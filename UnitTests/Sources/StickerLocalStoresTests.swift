//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

@testable import ElementX
import Foundation
import Testing

@MainActor
final class StickerLocalStoresTests {
    private let directory: URL
    
    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "StickerLocalStoresTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    
    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
    
    @Test
    func recentStickersMoveToTheFrontAndKeepThirty() {
        let recents = RecentsStore<StickerImage>.stickers(directory: directory)
        
        for index in 0..<35 {
            recents.add(sticker(index))
        }
        recents.add(sticker(20))
        
        let urls = recents.itemsPublisher.value.map(\.url)
        #expect(urls.count == 30)
        #expect(urls.first == sticker(20).url)
        #expect(urls[1] == sticker(34).url)
        #expect(urls.last == sticker(5).url)
        #expect(Set(urls).count == 30)
    }
    
    @Test
    func recentsSurviveARelaunchAndCanBeRemoved() {
        let file = SessionFile(url: directory.appending(path: "recents.json"))
        let recents = RecentsStore<String>(file: file) { $0 }
        recents.add("a")
        recents.add("b")
        recents.remove(id: "a")
        file.waitForWrites()
        
        let relaunched = RecentsStore<String>(file: file) { $0 }
        
        #expect(relaunched.itemsPublisher.value == ["b"])
    }
    
    @Test
    func recentStickersKeepTheWholeImageObject() {
        let file = SessionFile(url: directory.appending(path: "gua-recent-stickers.json"))
        let image = sticker(1).with(added: 42)
        RecentsStore<StickerImage>.stickers(directory: directory).add(image)
        file.waitForWrites()
        
        #expect(RecentsStore<StickerImage>.stickers(directory: directory).itemsPublisher.value == [image])
    }
    
    @Test
    func glyphUploadsAreRemembered() {
        let file = SessionFile(url: directory.appending(path: "glyphs.json"))
        StickerGlyphCache(file: file).store(sticker(1), forContentIdentifier: "genmoji-1")
        file.waitForWrites()
        
        let cache = StickerGlyphCache(file: file)
        
        #expect(cache.image(forContentIdentifier: "genmoji-1") == sticker(1))
        #expect(cache.image(forContentIdentifier: "genmoji-2") == nil)
    }
    
    @Test
    func accountDataCacheKeepsEachTypeApart() {
        let cache = AccountDataCache(directory: directory)
        cache.save(#"{"v":1}"#, type: StickerLibrary.accountDataType)
        cache.save(#"{"favourites":[]}"#, type: GifFavourites.accountDataType)
        SessionFile(url: directory.appending(path: "account-data-global.gua.stickers.json")).waitForWrites()
        
        let reloaded = AccountDataCache(directory: directory)
        
        #expect(reloaded.load(type: StickerLibrary.accountDataType) == #"{"v":1}"#)
        #expect(reloaded.load(type: GifFavourites.accountDataType) == #"{"favourites":[]}"#)
    }
    
    private func sticker(_ index: Int) -> StickerImage {
        StickerImage(url: "mxc://gua.global/\(index)", body: "S\(index)", info: StickerImageInfo(width: 256, height: 256, mimetype: "image/png", size: 100))
    }
}
