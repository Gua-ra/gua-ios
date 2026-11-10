//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

@MainActor
final class AccountDataWriteGate {
    private var waiting: [CheckedContinuation<Result<Void, ClientProxyError>, Never>] = []
    
    func write() async -> Result<Void, ClientProxyError> {
        await withCheckedContinuation { waiting.append($0) }
    }
    
    func waitForWriters(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<1000 {
            if waiting.count >= count {
                return
            }
            await Task.yield()
        }
        Issue.record("Expected \(count) pending writes, found \(waiting.count)", sourceLocation: sourceLocation)
    }
    
    func release(_ result: Result<Void, ClientProxyError> = .success(()), sourceLocation: SourceLocation = #_sourceLocation) {
        guard !waiting.isEmpty else {
            Issue.record("No write is waiting to be released.", sourceLocation: sourceLocation)
            return
        }
        waiting.removeFirst().resume(returning: result)
    }
}
