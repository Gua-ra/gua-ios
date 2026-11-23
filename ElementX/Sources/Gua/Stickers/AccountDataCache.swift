//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

protocol AccountDataCacheProtocol {
    func load(type: String) -> String?
    func save(_ contentJSON: String, type: String)
}

final class AccountDataCache: AccountDataCacheProtocol {
    private let directory: URL
    private var files: [String: SessionFile] = [:]
    
    init(directory: URL) {
        self.directory = directory
    }
    
    func load(type: String) -> String? {
        file(for: type).read().flatMap { String(data: $0, encoding: .utf8) }
    }
    
    func save(_ contentJSON: String, type: String) {
        file(for: type).write(Data(contentJSON.utf8))
    }
    
    private func file(for type: String) -> SessionFile {
        if let file = files[type] {
            return file
        }
        let file = SessionFile(url: directory.appending(path: "account-data-\(type).json"))
        files[type] = file
        return file
    }
}
