//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation

final class StickersAndGifs {
    let library: StickerLibrarySetting
    let gifFavourites: GifFavouritesSetting
    let recentStickers: RecentsStore<StickerImage>
    let recentGifs: RecentsStore<String>
    let glyphCache: StickerGlyphCache
    let packClient: StickerPackClientProtocol
    let gifProvider: GifProvider
    
    private var flagCancellable: AnyCancellable?
    
    init(clientProxy: ClientProxyProtocol,
         appSettings: AppSettings,
         sessionDirectories: SessionDirectories,
         gifProvider: GifProvider = KlipyGifProvider(configuration: .bundled)) {
        let cache = AccountDataCache(directory: sessionDirectories.cacheDirectory)
        library = StickerLibrarySetting(clientProxy: clientProxy, cache: cache)
        gifFavourites = GifFavouritesSetting(clientProxy: clientProxy, cache: cache)
        recentStickers = .stickers(directory: sessionDirectories.dataDirectory)
        recentGifs = .gifs(directory: sessionDirectories.dataDirectory)
        glyphCache = StickerGlyphCache(directory: sessionDirectories.dataDirectory)
        packClient = StickerPackClient(homeserver: { clientProxy.homeserver }, accessToken: { clientProxy.accessToken })
        self.gifProvider = gifProvider
        
        // Production builds never read the account data until the feature is turned on.
        flagCancellable = appSettings.guaStickersAndGifsEnabledPublisher
            .first { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.library.start()
                self?.gifFavourites.start()
            }
    }
}
