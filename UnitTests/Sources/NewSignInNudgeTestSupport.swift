//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import Foundation

/// Answers the client-server calls `OwnDevicesClient` makes and records every request it receives.
final class OwnDevicesHTTPStub: URLProtocol {
    struct Request {
        let method: String
        let path: String
        let authorization: String?
        let body: Data

        var json: NSDictionary? {
            (try? JSONSerialization.jsonObject(with: body)) as? NSDictionary
        }
    }

    typealias Responder = (Request) -> (status: Int, body: String)

    private static let lock = NSLock()
    private static var recordedRequests: [Request] = []
    private static var responder: Responder = { _ in (404, "{}") }

    static var requests: [Request] {
        lock.withLock { recordedRequests }
    }

    static var nudges: [Request] {
        requests.filter { $0.method == "PUT" && $0.path.hasPrefix("/_matrix/client/v3/sendToDevice/") }
    }

    static func respond(_ newResponder: @escaping Responder) {
        lock.withLock { responder = newResponder }
    }

    static func reset() {
        lock.withLock {
            recordedRequests = []
            responder = { _ in (404, "{}") }
        }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OwnDevicesHTTPStub.self]
        return URLSession(configuration: configuration)
    }

    /// Serves `/devices` and `/keys/query` from the fixtures and accepts every nudge.
    static func serve(devices: @escaping () -> String, keys: @escaping () -> String) {
        respond { request in
            switch (request.method, request.path) {
            case ("GET", "/_matrix/client/v3/devices"):
                return (200, devices())
            case ("POST", "/_matrix/client/v3/keys/query"):
                return (200, keys())
            case ("PUT", let path) where path.hasPrefix("/_matrix/client/v3/sendToDevice/global.gua.verification.retry_request/"):
                return (200, "{}")
            default:
                return (404, #"{"errcode":"M_UNRECOGNIZED"}"#)
            }
        }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else { return }
        let recorded = Request(method: request.httpMethod ?? "GET",
                               path: url.path(percentEncoded: false),
                               authorization: request.value(forHTTPHeaderField: "Authorization"),
                               body: request.httpBody ?? Self.readBody(of: request))
        let answer = Self.lock.withLock {
            Self.recordedRequests.append(recorded)
            return Self.responder(recorded)
        }

        guard let response = HTTPURLResponse(url: url,
                                             statusCode: answer.status,
                                             httpVersion: nil,
                                             headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }

    private static func readBody(of request: URLRequest) -> Data {
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(contentsOf: buffer[0..<read])
        }
        return data
    }
}

/// Builds `/devices` and `/keys/query` bodies for one account.
struct OwnDevicesFixture {
    struct Device {
        var id: String
        var lastSeen: Date?
        var signedBySelfSigningKey = false
        var dehydrated: Bool?
        var listedInDevices = true
    }

    let userID: String
    var selfSigningPublicKey: String? = "SSKPUBLICKEY"
    var devices: [Device]

    var devicesJSON: String {
        let entries: [[String: Any]] = devices.filter(\.listedInDevices).map { device in
            var entry: [String: Any] = ["device_id": device.id, "display_name": "Device \(device.id)"]
            if let lastSeen = device.lastSeen {
                entry["last_seen_ts"] = Int64(lastSeen.timeIntervalSince1970 * 1000)
                entry["last_seen_ip"] = "192.0.2.1"
            }
            return entry
        }
        return Self.json(["devices": entries])
    }

    var keysJSON: String {
        var deviceKeys: [String: Any] = [:]
        for device in devices {
            var signatures = ["ed25519:\(device.id)": "self-signature"]
            if device.signedBySelfSigningKey, let selfSigningPublicKey {
                signatures["ed25519:\(selfSigningPublicKey)"] = "cross-signature"
            }
            var keys: [String: Any] = ["user_id": userID,
                                       "device_id": device.id,
                                       "algorithms": ["m.olm.v1.curve25519-aes-sha2", "m.megolm.v1.aes-sha2"],
                                       "keys": ["ed25519:\(device.id)": "ed-\(device.id)", "curve25519:\(device.id)": "curve-\(device.id)"],
                                       "signatures": [userID: signatures]]
            if let dehydrated = device.dehydrated {
                keys["dehydrated"] = dehydrated
            }
            deviceKeys[device.id] = keys
        }

        var body: [String: Any] = ["failures": [:],
                                   "device_keys": [userID: deviceKeys],
                                   "master_keys": [userID: ["user_id": userID, "usage": ["master"], "keys": ["ed25519:MASTER": "MASTER"]]]]
        if let selfSigningPublicKey {
            body["self_signing_keys"] = [userID: ["user_id": userID,
                                                  "usage": ["self_signing"],
                                                  "keys": ["ed25519:\(selfSigningPublicKey)": selfSigningPublicKey],
                                                  "signatures": [userID: ["ed25519:MASTER": "master-signature"]]]]
        }
        return Self.json(body)
    }

    private static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }
}

/// Runs scheduled work only when a test fires it.
@MainActor
final class ManualNewSignInNudgeScheduler: NewSignInNudgeScheduling {
    final class Entry {
        let delay: Duration
        let repeats: Bool
        let work: @MainActor () -> Void
        var isCancelled = false
        var hasFired = false

        var isLive: Bool {
            !isCancelled && !(hasFired && !repeats)
        }

        init(delay: Duration, repeats: Bool, work: @escaping @MainActor () -> Void) {
            self.delay = delay
            self.repeats = repeats
            self.work = work
        }
    }

    private(set) var entries: [Entry] = []

    var liveEntries: [Entry] {
        entries.filter(\.isLive)
    }

    func after(_ delay: Duration, _ work: @escaping @MainActor () -> Void) -> AnyCancellable {
        schedule(Entry(delay: delay, repeats: false, work: work))
    }

    func every(_ interval: Duration, _ work: @escaping @MainActor () -> Void) -> AnyCancellable {
        schedule(Entry(delay: interval, repeats: true, work: work))
    }

    /// Runs every live entry scheduled with `delay`, as if that much time had passed for it.
    func fire(_ delay: Duration) {
        for entry in liveEntries where entry.delay == delay {
            entry.hasFired = true
            entry.work()
        }
    }

    private func schedule(_ entry: Entry) -> AnyCancellable {
        entries.append(entry)
        return AnyCancellable { entry.isCancelled = true }
    }
}

final class NewSignInNudgeTestClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}
