//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

struct ResolverDocumentFetcher {
    enum Failure: Error, Equatable {
        case status(Int)
        case unavailable
        case timeout
        case malformed

        func reason(unavailable: ResolverVerificationReason) -> ResolverVerificationReason {
            switch self {
            case .timeout: .timeout
            case .malformed: .parseError
            case .status, .unavailable: unavailable
            }
        }
    }

    static let maxBodyBytes = 2 * 1024 * 1024
    static let maxNestingDepth = 64

    let baseURL: URL
    let session: URLSession

    func document<Document: Decodable>(_ type: Document.Type, at path: String, query: [URLQueryItem] = [],
                                       deadline: ContinuousClock.Instant) async throws(Failure) -> Document {
        let body = try await fetchBody(at: path, query: query, deadline: deadline)
        guard Self.isNestedWithinLimit(body) else { throw .malformed }
        do {
            return try JSONDecoder().decode(type, from: Data(body))
        } catch {
            throw .malformed
        }
    }

    /// Counts brackets outside strings without recursing, so a deep document is refused before any parser walks it.
    static func isNestedWithinLimit(_ body: [UInt8]) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false
        for byte in body {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                inString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                depth += 1
                if depth > maxNestingDepth { return false }
            case UInt8(ascii: "]"), UInt8(ascii: "}"):
                depth -= 1
            default:
                break
            }
        }
        return true
    }

    private func fetchBody(at path: String, query: [URLQueryItem], deadline: ContinuousClock.Instant) async throws(Failure) -> [UInt8] {
        guard deadline > .now else { throw .timeout }
        guard let relative = URL(string: path, relativeTo: baseURL),
              var components = URLComponents(url: relative, resolvingAgainstBaseURL: true) else {
            throw .unavailable
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw .unavailable }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            return try await withThrowingTaskGroup(of: [UInt8].self) { [session, request] group in
                group.addTask { try await Self.read(request, from: session) }
                group.addTask {
                    try await Task.sleep(until: deadline, clock: .continuous)
                    throw Failure.timeout
                }
                defer { group.cancelAll() }
                guard let body = try await group.next() else { throw Failure.unavailable }
                return body
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw .unavailable
        }
    }

    private static func read(_ request: URLRequest, from session: URLSession) async throws -> [UInt8] {
        let (stream, response) = try await session.bytes(for: request)
        defer { stream.task.cancel() }
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw Failure.unavailable }
        guard (200..<300).contains(status) else { throw Failure.status(status) }
        var body = [UInt8]()
        for try await byte in stream {
            guard body.count < maxBodyBytes else { throw Failure.malformed }
            body.append(byte)
        }
        return body
    }
}
