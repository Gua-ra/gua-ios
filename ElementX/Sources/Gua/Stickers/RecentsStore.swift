//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation

/// This device's recently sent items, never synced.
final class RecentsStore<Item: Codable & Equatable & Sendable> {
    static var defaultLimit: Int {
        30
    }
    
    private let file: SessionFile
    private let limit: Int
    private let identity: (Item) -> String
    private let subject: CurrentValueSubject<[Item], Never>
    
    var itemsPublisher: CurrentValuePublisher<[Item], Never> {
        subject.asCurrentValuePublisher()
    }
    
    init(file: SessionFile, limit: Int = defaultLimit, identity: @escaping (Item) -> String) {
        self.file = file
        self.limit = limit
        self.identity = identity
        let items = file.read().flatMap { try? JSONDecoder().decode([Item].self, from: $0) } ?? []
        subject = CurrentValueSubject(Array(items.prefix(limit)))
    }
    
    func add(_ item: Item) {
        let id = identity(item)
        save(Array(([item] + subject.value.filter { identity($0) != id }).prefix(limit)))
    }
    
    func remove(id: String) {
        save(subject.value.filter { identity($0) != id })
    }
    
    private func save(_ items: [Item]) {
        guard items != subject.value else { return }
        subject.send(items)
        if let data = try? JSONEncoder().encode(items) {
            file.write(data)
        }
    }
}

extension RecentsStore where Item == StickerImage {
    static func stickers(directory: URL) -> RecentsStore<StickerImage> {
        RecentsStore(file: SessionFile(url: directory.appending(path: "gua-recent-stickers.json"))) { $0.url }
    }
}

extension RecentsStore where Item == String {
    static func gifs(directory: URL) -> RecentsStore<String> {
        RecentsStore(file: SessionFile(url: directory.appending(path: "gua-recent-gifs.json"))) { $0 }
    }
}
