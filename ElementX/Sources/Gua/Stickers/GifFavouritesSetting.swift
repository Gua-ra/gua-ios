//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

final class GifFavouritesSetting {
    private let setting: AccountDataSetting<GifFavourites>
    
    var favouritesPublisher: CurrentValuePublisher<GifFavourites, Never> {
        setting.valuePublisher
    }
    
    init(clientProxy: ClientProxyProtocol,
         cache: AccountDataCacheProtocol,
         echoTimeout: TimeInterval = 30,
         syncThrottle: DispatchQueue.SchedulerTimeType.Stride = .seconds(5)) {
        setting = AccountDataSetting(accountDataType: GifFavourites.accountDataType,
                                     clientProxy: clientProxy,
                                     cache: cache,
                                     decode: GifFavourites.init(contentJSON:),
                                     encode: \.contentJSON,
                                     echoTimeout: echoTimeout,
                                     syncThrottle: syncThrottle)
    }
    
    func start() {
        setting.start()
    }
    
    func refresh(afterSync: Bool = false) async {
        await setting.refresh(afterSync: afterSync)
    }
    
    func favourite(id: String, provider: String) async -> Result<Void, ClientProxyError> {
        var favourites = favouritesPublisher.value
        favourites.favourite(id: id, provider: provider)
        return await setting.set(favourites)
    }
    
    func unfavourite(id: String, provider: String) async -> Result<Void, ClientProxyError> {
        var favourites = favouritesPublisher.value
        favourites.unfavourite(id: id, provider: provider)
        return await setting.set(favourites)
    }
}
