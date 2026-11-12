//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

extension StickersAndGifs {
    /// Owns its client, so the account data reads it makes once the flag is on never count against a test's client.
    static func mock(appSettings: AppSettings) -> StickersAndGifs {
        let emptyPage = GifPage(items: [], page: 1, hasNext: false)
        let gifProvider = GifProviderMock()
        gifProvider.underlyingId = KlipyGifProvider.providerID
        gifProvider.underlyingIsAvailable = true
        gifProvider.searchPageReturnValue = .success(emptyPage)
        gifProvider.trendingPageReturnValue = .success(emptyPage)
        gifProvider.itemsIdsReturnValue = .success([])
        gifProvider.dataFromReturnValue = .failure(.unavailable)
        
        let packClient = StickerPackClientMock()
        packClient.packEventsRoomIDReturnValue = .success([])
        
        // Never created, so the mocks leave nothing on disk and a test that saves recents only logs the failed write.
        let directory = URL.temporaryDirectory.appending(path: "StickersAndGifsMock-\(UUID().uuidString)")
        let directories = SessionDirectories(dataDirectory: directory.appending(path: "data"), cacheDirectory: directory.appending(path: "cache"))
        
        return StickersAndGifs(clientProxy: ClientProxyMock(.init()),
                               appSettings: appSettings,
                               sessionDirectories: directories,
                               gifProvider: gifProvider,
                               packClient: packClient)
    }
}
