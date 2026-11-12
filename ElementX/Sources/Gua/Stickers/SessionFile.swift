//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

final nonisolated class SessionFile: Sendable {
    private static let writeQueue = DispatchQueue(label: "global.gua.session-files", qos: .utility)
    
    let url: URL
    
    init(url: URL) {
        self.url = url
    }
    
    func read() -> Data? {
        try? Data(contentsOf: url)
    }
    
    func write(_ data: Data) {
        Self.writeQueue.async { [url] in
            // Never recreates the directory, so a write landing after sign-out deleted the session fails.
            do {
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                MXLog.error("Failed writing \(url.lastPathComponent): \(error)")
            }
        }
    }
    
    /// Waits for every session file's pending writes.
    func waitForWrites() {
        Self.writeQueue.sync { }
    }
}
