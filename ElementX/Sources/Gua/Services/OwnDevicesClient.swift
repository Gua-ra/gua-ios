//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum OwnDevicesClientError: Error {
    case invalidURL
    /// 401: the access token expired or was revoked. The SDK refreshes it on its own, so the caller
    /// only skips this attempt; it is never a reason to sign out.
    case unauthorized
    case server(status: Int)
    case transport(Error)
    case decoding(Error)
}

/// One entry of `GET /_matrix/client/v3/devices`.
struct OwnDevice: Equatable {
    let deviceID: String
    let lastSeen: Date?
}

/// What `POST /_matrix/client/v3/keys/query` reports about the account's own devices.
struct OwnDeviceKeys: Equatable {
    struct Device: Equatable {
        let isDehydrated: Bool
        /// Key ids of the account owner's signatures on this device's keys.
        let ownerSignatureKeyIDs: Set<String>
    }

    /// `ed25519:<public key>` ids of the account's self-signing key. Empty when the account has none.
    let selfSigningKeyIDs: Set<String>
    let devices: [String: Device]
}

/// Raw client-server calls the SDK does not expose: the account's device list, its own device keys,
/// and the Gua verification retry nudge sent to one device.
final class OwnDevicesClient {
    static let verificationRetryEventType = "global.gua.verification.retry_request"

    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let timeout: TimeInterval = 15

    init(session: URLSession = .shared) {
        self.session = session
    }

    func devices(homeserver: String, accessToken: String) async throws -> [OwnDevice] {
        struct Response: Decodable {
            struct Device: Decodable {
                let deviceID: String
                let lastSeenTimestamp: Int64?

                enum CodingKeys: String, CodingKey {
                    case deviceID = "device_id"
                    case lastSeenTimestamp = "last_seen_ts"
                }
            }

            let devices: [Device]
        }

        let request = try makeRequest(homeserver: homeserver, path: "/_matrix/client/v3/devices", method: "GET", accessToken: accessToken, body: nil)
        let response: Response = try await decode(send(request))
        return response.devices.map { device in
            OwnDevice(deviceID: device.deviceID,
                      lastSeen: device.lastSeenTimestamp.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) })
        }
    }

    func deviceKeys(homeserver: String, accessToken: String, userID: String) async throws -> OwnDeviceKeys {
        struct Body: Encodable {
            let deviceKeys: [String: [String]]

            enum CodingKeys: String, CodingKey {
                case deviceKeys = "device_keys"
            }
        }

        struct Response: Decodable {
            struct DeviceKeys: Decodable {
                let signatures: [String: [String: String]]?
                let dehydrated: Bool?
            }

            struct CrossSigningKey: Decodable {
                let keys: [String: String]
            }

            let deviceKeys: [String: [String: DeviceKeys]]?
            let selfSigningKeys: [String: CrossSigningKey]?

            enum CodingKeys: String, CodingKey {
                case deviceKeys = "device_keys"
                case selfSigningKeys = "self_signing_keys"
            }
        }

        let body = try encode(Body(deviceKeys: [userID: []]))
        let request = try makeRequest(homeserver: homeserver, path: "/_matrix/client/v3/keys/query", method: "POST", accessToken: accessToken, body: body)
        let response: Response = try await decode(send(request))

        let selfSigningKeyIDs = Set(response.selfSigningKeys?[userID]?.keys.keys.filter { $0.hasPrefix("ed25519:") } ?? [])
        let devices = (response.deviceKeys?[userID] ?? [:]).mapValues { keys in
            OwnDeviceKeys.Device(isDehydrated: keys.dehydrated == true,
                                 ownerSignatureKeyIDs: Set(keys.signatures?[userID].map { Array($0.keys) } ?? []))
        }
        return OwnDeviceKeys(selfSigningKeyIDs: selfSigningKeyIDs, devices: devices)
    }

    /// Unencrypted to-device event asking `targetDeviceID` to send its verification request again.
    func sendVerificationRetryRequest(homeserver: String,
                                      accessToken: String,
                                      userID: String,
                                      targetDeviceID: String,
                                      fromDeviceID: String,
                                      transactionID: String) async throws {
        struct Body: Encodable {
            let messages: [String: [String: [String: String]]]
        }

        let path = try "/_matrix/client/v3/sendToDevice/\(Self.verificationRetryEventType)/\(Self.pathComponent(transactionID))"
        let body = try encode(Body(messages: [userID: [targetDeviceID: ["from_device": fromDeviceID]]]))
        let request = try makeRequest(homeserver: homeserver, path: path, method: "PUT", accessToken: accessToken, body: body)
        _ = try await send(request)
    }

    // MARK: - Private

    private func makeRequest(homeserver: String, path: String, method: String, accessToken: String, body: Data?) throws -> URLRequest {
        var base = homeserver
        while base.hasSuffix("/") {
            base.removeLast()
        }
        guard let url = URL(string: base + path), url.scheme == "https" || url.scheme == "http", url.host() != nil else {
            throw OwnDevicesClientError.invalidURL
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OwnDevicesClientError.transport(error)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OwnDevicesClientError.server(status: -1)
        }
        switch httpResponse.statusCode {
        case 200..<300:
            return data
        case 401:
            throw OwnDevicesClientError.unauthorized
        default:
            throw OwnDevicesClientError.server(status: httpResponse.statusCode)
        }
    }

    private func encode(_ value: some Encodable) throws -> Data {
        do {
            return try encoder.encode(value)
        } catch {
            throw OwnDevicesClientError.transport(error)
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw OwnDevicesClientError.decoding(error)
        }
    }

    private static func pathComponent(_ value: String) throws -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        guard let escaped = value.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw OwnDevicesClientError.invalidURL
        }
        return escaped
    }
}
