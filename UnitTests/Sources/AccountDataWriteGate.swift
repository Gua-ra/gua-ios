//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import XCTest

@MainActor
final class AccountDataWriteGate {
    private var waiting: [CheckedContinuation<Result<Void, ClientProxyError>, Never>] = []

    func write() async -> Result<Void, ClientProxyError> {
        await withCheckedContinuation { waiting.append($0) }
    }

    func waitForWriters(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 {
            if waiting.count >= count { return }
            await Task.yield()
        }
        XCTFail("Expected \(count) pending writes, found \(waiting.count)", file: file, line: line)
    }

    func release(_ result: Result<Void, ClientProxyError> = .success(()), file: StaticString = #filePath, line: UInt = #line) {
        guard !waiting.isEmpty else {
            XCTFail("No write is waiting to be released.", file: file, line: line)
            return
        }
        waiting.removeFirst().resume(returning: result)
    }
}
