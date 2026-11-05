//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

struct OwnDevice: Equatable {
    let deviceID: String
    let lastSeen: Date?
}

struct OwnDeviceKeys: Equatable {
    struct Device: Equatable {
        let isDehydrated: Bool
        let ownerSignatureKeyIDs: Set<String>
    }

    /// `ed25519:<public key>` ids, the same form as the key ids in a device's signatures.
    let selfSigningKeyIDs: Set<String>
    let devices: [String: Device]
}

/// Client-server calls the SDK does not expose.
final class OwnDevicesClient {
    static let verificationRetryEventType = "global.gua.verification.retry_request"

    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

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

        let request = try ClientServerHTTP.makeRequest(homeserver: homeserver, path: "/_matrix/client/v3/devices", method: "GET", accessToken: accessToken)
        let response: Response = try await decode(ClientServerHTTP.send(request, session: session))
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
        let request = try ClientServerHTTP.makeRequest(homeserver: homeserver, path: "/_matrix/client/v3/keys/query", method: "POST", accessToken: accessToken, body: body)
        let response: Response = try await decode(ClientServerHTTP.send(request, session: session))

        let selfSigningKeyIDs = Set(response.selfSigningKeys?[userID]?.keys.keys.filter { $0.hasPrefix("ed25519:") } ?? [])
        let devices = (response.deviceKeys?[userID] ?? [:]).mapValues { keys in
            OwnDeviceKeys.Device(isDehydrated: keys.dehydrated == true,
                                 ownerSignatureKeyIDs: Set(keys.signatures?[userID].map { Array($0.keys) } ?? []))
        }
        return OwnDeviceKeys(selfSigningKeyIDs: selfSigningKeyIDs, devices: devices)
    }

    func sendVerificationRetryRequest(homeserver: String,
                                      accessToken: String,
                                      userID: String,
                                      targetDeviceID: String,
                                      fromDeviceID: String,
                                      transactionID: String) async throws {
        struct Body: Encodable {
            let messages: [String: [String: [String: String]]]
        }

        let path = try "/_matrix/client/v3/sendToDevice/\(Self.verificationRetryEventType)/\(ClientServerHTTP.pathComponent(transactionID))"
        let body = try encode(Body(messages: [userID: [targetDeviceID: ["from_device": fromDeviceID]]]))
        let request = try ClientServerHTTP.makeRequest(homeserver: homeserver, path: path, method: "PUT", accessToken: accessToken, body: body)
        _ = try await ClientServerHTTP.send(request, session: session)
    }

    private func encode(_ value: some Encodable) throws -> Data {
        do {
            return try encoder.encode(value)
        } catch {
            throw ClientServerError.transport
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ClientServerError.decoding
        }
    }
}
