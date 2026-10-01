//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation

/// `baseURL` is used directly: well-known discovery fails for http and localhost homeservers.
struct ResolvedHomeserver: Equatable {
    let serverName: String
    let baseURL: String
    let masIssuer: String?
    let region: String?
}

struct HomeserverResolution: Equatable {
    let exists: Bool
    let homeserver: ResolvedHomeserver
    var trace: DecisionTrace?
}

/// Nil fields are omitted, so a plain resolve sends only `{"phone"}`.
struct ResolveOptions: Encodable, Equatable {
    var country: String?
    var mccmnc: String?
    var carrier: String?
    var regionHint: String?
    var affiliations: [String]?
    var attributes: [String: String]?
    var routingClaims: RoutingClaimsEnvelope?
    var trace: Bool?
}

/// Opaque signed envelope: the client forwards it and never creates or alters one.
struct RoutingClaimsEnvelope: Codable, Equatable {
    let schemaVersion: String
    let issuer: String
    let audience: String
    let issuedAt: String
    let expiresAt: String
    let nonce: String
    let subject: String
    let affiliations: [String]?
    let attributes: [String: String]?
    let signatures: [ClaimSignature]
}

struct ClaimSignature: Codable, Equatable {
    let keyId: String
    let signatureB64: String
}

struct DecisionTrace: Decodable, Equatable {
    let source: String
    let rule: String
    let ruleId: String?
    let reason: String?
    let policyId: String?
    let policyVersion: Int64?
    let delegatedZoneId: String?
    let assignmentPolicy: String?
    let homeserverId: String?
    /// Informational: the client does not verify or pin the roster.
    let rosterVersion: Int64?
}

struct FederationRosterServer: Decodable, Equatable {
    let serverName: String
    let searchVisibility: String?
    let searchGroups: [String]?
}

struct FederationRosterEntry: Decodable, Equatable {
    let homeserver: FederationRosterServer
    let status: String

    var isActive: Bool {
        status == "ACTIVE"
    }
}

struct FederationRoster: Decodable, Equatable {
    let entries: [FederationRosterEntry]
}

enum ResolverError: Error, LocalizedError {
    case notConfigured
    case invalidURL
    case malformedResponse
    case server(status: Int)
    case transport(Error)
    case decoding(Error)

    case invalidPhone
    case invalidRoutingClaims
    case directoryUnavailable
    case noPlacementAvailable

    var errorDescription: String? {
        switch self {
        case .notConfigured: "The routing service is not configured."
        case .invalidURL: "The routing service URL is invalid."
        case .malformedResponse: "The routing service returned an unexpected response."
        case let .server(status): "Routing service error (\(status))."
        case let .transport(error): error.localizedDescription
        case let .decoding(error): "Could not parse the routing service response: \(error.localizedDescription)"
        case .invalidPhone: "The routing service rejected the phone number."
        case .invalidRoutingClaims: "The routing service rejected the signed routing claims."
        case .directoryUnavailable: "The routing directory is temporarily unavailable."
        case .noPlacementAvailable: "No homeserver is currently accepting new accounts."
        }
    }

    var userFacingMessage: String {
        switch self {
        case .invalidPhone:
            L10n.screenPhoneLoginInvalidNumber
        case .invalidRoutingClaims:
            UntranslatedL10n.guaResolverClaimsInvalid
        case .directoryUnavailable:
            UntranslatedL10n.guaResolverRoutingUnavailable
        case .noPlacementAvailable:
            UntranslatedL10n.guaResolverRegistrationClosed
        case let .server(status) where (400...499).contains(status):
            L10n.screenPhoneLoginInvalidNumber
        case .server, .transport, .decoding, .malformedResponse, .invalidURL, .notConfigured:
            L10n.errorUnknown
        }
    }
}

protocol ResolverClientProtocol: Sendable {
    func resolve(phoneNumber: String) async throws -> HomeserverResolution

    func resolve(phoneNumber: String, options: ResolveOptions) async throws -> HomeserverResolution
}

extension ResolverClientProtocol {
    func resolve(phoneNumber: String, options: ResolveOptions) async throws -> HomeserverResolution {
        try await resolve(phoneNumber: phoneNumber)
    }
}

protocol FederationRosterFetching: Sendable {
    func fetchRoster() async throws -> FederationRoster
}

final class ResolverClient: ResolverClientProtocol, FederationRosterFetching {
    private let baseURL: URL
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    convenience init?() {
        guard let url = GuaDeployment.current.resolverBaseURL else { return nil }
        self.init(baseURL: url)
    }

    func resolve(phoneNumber: String) async throws -> HomeserverResolution {
        try await resolve(phoneNumber: phoneNumber, options: ResolveOptions())
    }

    func resolve(phoneNumber: String, options: ResolveOptions) async throws -> HomeserverResolution {
        struct RequestBody: Encodable {
            let phone: String
            let country: String?
            let mccmnc: String?
            let carrier: String?
            let regionHint: String?
            let affiliations: [String]?
            let attributes: [String: String]?
            let routingClaims: RoutingClaimsEnvelope?
            let trace: Bool?
        }
        struct HomeserverRef: Decodable {
            let serverName: String
            let baseUrl: String
            let masIssuer: String?
            let region: String?
        }
        struct Response: Decodable {
            let exists: Bool
            let homeserver: HomeserverRef?
            let registerAt: HomeserverRef?
            let trace: DecisionTrace?
        }

        guard let url = URL(string: "/resolve", relativeTo: baseURL) else { throw ResolverError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            request.httpBody = try encoder.encode(RequestBody(phone: phoneNumber,
                                                              country: options.country,
                                                              mccmnc: options.mccmnc,
                                                              carrier: options.carrier,
                                                              regionHint: options.regionHint,
                                                              affiliations: options.affiliations,
                                                              attributes: options.attributes,
                                                              routingClaims: options.routingClaims,
                                                              trace: options.trace))
        } catch {
            throw ResolverError.decoding(error)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ResolverError.transport(error)
        }
        guard let httpResponse = response as? HTTPURLResponse else { throw ResolverError.malformedResponse }
        guard httpResponse.statusCode == 200 else {
            throw resolveError(status: httpResponse.statusCode, body: data)
        }

        let parsed: Response
        do {
            parsed = try decoder.decode(Response.self, from: data)
        } catch {
            throw ResolverError.decoding(error)
        }

        guard let ref = parsed.exists ? parsed.homeserver : parsed.registerAt else {
            throw ResolverError.malformedResponse
        }
        return HomeserverResolution(exists: parsed.exists,
                                    homeserver: ResolvedHomeserver(serverName: ref.serverName,
                                                                   baseURL: ref.baseUrl,
                                                                   masIssuer: ref.masIssuer,
                                                                   region: ref.region),
                                    trace: parsed.trace)
    }

    private func resolveError(status: Int, body: Data) -> ResolverError {
        struct ProblemResponse: Decodable {
            let code: String?
            let message: String?
        }
        return switch (try? decoder.decode(ProblemResponse.self, from: body))?.code {
        case "invalid_phone": .invalidPhone
        case "invalid_routing_claims": .invalidRoutingClaims
        case "directory_unavailable": .directoryUnavailable
        case "no_placement_available": .noPlacementAvailable
        default: .server(status: status)
        }
    }

    func fetchRoster() async throws -> FederationRoster {
        guard let url = URL(string: "/roster", relativeTo: baseURL) else { throw ResolverError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ResolverError.transport(error)
        }
        guard let httpResponse = response as? HTTPURLResponse else { throw ResolverError.malformedResponse }
        guard httpResponse.statusCode == 200 else { throw ResolverError.server(status: httpResponse.statusCode) }

        do {
            return try decoder.decode(FederationRoster.self, from: data)
        } catch {
            throw ResolverError.decoding(error)
        }
    }
}
