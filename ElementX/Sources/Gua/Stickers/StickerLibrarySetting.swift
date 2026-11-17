//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

enum StickerLibraryUpdateError: Error {
    case limitReached
    case writeFailed(ClientProxyError)
}

final class StickerLibrarySetting {
    private let setting: AccountDataSetting<StickerLibrary>
    
    var libraryPublisher: CurrentValuePublisher<StickerLibrary, Never> {
        setting.valuePublisher
    }
    
    init(clientProxy: ClientProxyProtocol,
         cache: AccountDataCacheProtocol,
         echoTimeout: TimeInterval = 30,
         syncThrottle: DispatchQueue.SchedulerTimeType.Stride = .seconds(5)) {
        setting = AccountDataSetting(accountDataType: StickerLibrary.accountDataType,
                                     clientProxy: clientProxy,
                                     cache: cache,
                                     decode: StickerLibrary.init(contentJSON:),
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
    
    func add(_ image: StickerImage, now: Date = .now) async -> Result<StickerPackItem, StickerLibraryUpdateError> {
        var library = libraryPublisher.value
        let item: StickerPackItem
        do {
            item = try library.add(image, now: Int64(now.timeIntervalSince1970 * 1000))
        } catch {
            return .failure(.limitReached)
        }
        return await write(library).map { item }
    }
    
    func favourite(_ image: StickerImage) async -> Result<Void, StickerLibraryUpdateError> {
        await update { $0.favourite(image) }
    }
    
    func unfavourite(url: String) async -> Result<Void, StickerLibraryUpdateError> {
        await update { $0.unfavourite(url: url) }
    }
    
    func delete(shortcode: String) async -> Result<Void, StickerLibraryUpdateError> {
        await update { $0.delete(shortcode: shortcode) }
    }
    
    private func update(_ change: (inout StickerLibrary) -> Void) async -> Result<Void, StickerLibraryUpdateError> {
        var library = libraryPublisher.value
        change(&library)
        return await write(library)
    }
    
    private func write(_ library: StickerLibrary) async -> Result<Void, StickerLibraryUpdateError> {
        await setting.set(library).mapError(StickerLibraryUpdateError.writeFailed)
    }
}
