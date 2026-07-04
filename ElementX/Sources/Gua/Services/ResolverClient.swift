//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation

/// A homeserver as advertised by the Gua resolver: where a phone's account lives (login) or should be
/// created (register). The homeserver is identified by its Matrix `serverName`; the client configures OIDC
/// against that and discovers the base URL + MAS issuer via well-known, exactly as it would for any
/// account provider.
struct ResolvedHomeserver: Equatable {
    let serverName: String
    let baseURL: String
    let masIssuer: String?
    let region: String?
}

/// Outcome of resolving a phone number against the Gua resolver.
struct HomeserverResolution: Equatable {
    /// `true` when an account already exists for this phone (→ login); `false` when it does not (→ register).
    let exists: Bool
    /// The homeserver to authenticate against (login) or create the account on (register).
    let homeserver: ResolvedHomeserver
}

struct ResolverResolveOptions: Encodable, Equatable {
    var country: String?
    var mccmnc: String?
    var carrier: String?
    var regionHint: String?
    var affiliations: [String]?
    var attributes: [String: String]?
    var routingClaims: ResolverRoutingClaimsEnvelope?
    var trace: Bool?

    init(country: String? = nil,
         mccmnc: String? = nil,
         carrier: String? = nil,
         regionHint: String? = nil,
         affiliations: [String]? = nil,
         attributes: [String: String]? = nil,
         routingClaims: ResolverRoutingClaimsEnvelope? = nil,
         trace: Bool? = nil) {
        self.country = country
        self.mccmnc = mccmnc
        self.carrier = carrier
        self.regionHint = regionHint
        self.affiliations = affiliations
        self.attributes = attributes
        self.routingClaims = routingClaims
        self.trace = trace
    }
}

struct ResolverRoutingClaimsEnvelope: Encodable, Equatable {
    let schemaVersion: String
    let issuer: String
    let audience: String
    let issuedAt: String
    let expiresAt: String
    let nonce: String
    let affiliations: [String]?
    let attributes: [String: String]?
    let signatures: [ResolverClaimSignature]
}

struct ResolverClaimSignature: Encodable, Equatable {
    let keyId: String
    let signatureB64: String
}

struct ResolverDecisionTrace: Decodable, Equatable {
    let source: String
    let rule: String
    let ruleId: String?
    let reason: String?
    let policyId: String?
    let policyVersion: Int64?
    let delegatedZoneId: String?
    let assignmentPolicy: String?
    let homeserverId: String?
}

enum ResolverError: Error, LocalizedError {
    case notConfigured
    case invalidURL
    case malformedResponse
    case server(status: Int)
    case transport(Error)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "The routing service is not configured."
        case .invalidURL: "The routing service URL is invalid."
        case .malformedResponse: "The routing service returned an unexpected response."
        case let .server(status): "Routing service error (\(status))."
        case let .transport(error): error.localizedDescription
        case let .decoding(error): "Could not parse the routing service response: \(error.localizedDescription)"
        }
    }

    /// A short, user-facing message for the phone-entry screen. `errorDescription` stays technical for
    /// logs; this is what the user actually reads. A 4xx means the number we sent was rejected as invalid
    /// (the user can fix it); anything else is a service/network problem (retry).
    var userFacingMessage: String {
        switch self {
        case let .server(status) where (400...499).contains(status):
            L10n.screenPhoneLoginInvalidNumber
        case .server, .transport, .decoding, .malformedResponse, .invalidURL, .notConfigured:
            L10n.errorUnknown
        }
    }
}

protocol ResolverClientProtocol: Sendable {
    /// Resolve a verified phone number to the homeserver it belongs to (or should be created on).
    func resolve(phoneNumber: String) async throws -> HomeserverResolution
}

extension ResolverClientProtocol {
    func resolve(phoneNumber: String, options: ResolverResolveOptions) async throws -> HomeserverResolution {
        try await resolve(phoneNumber: phoneNumber)
    }
}

/// Talks to the Gua resolver (`POST /resolve`) — the federation front door that maps a phone number to a
/// homeserver, so the client never hardcodes one. See `gua-resolver`.
final class ResolverClient: ResolverClientProtocol {
    private let baseURL: URL
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Convenience initializer using the active `GuaDeployment`'s resolver URL. Returns `nil` when the
    /// resolver is not configured.
    convenience init?() {
        guard let url = GuaDeployment.current.resolverBaseURL else { return nil }
        self.init(baseURL: url)
    }

    func resolve(phoneNumber: String) async throws -> HomeserverResolution {
        try await resolve(phoneNumber: phoneNumber, options: ResolverResolveOptions())
    }

    func resolve(phoneNumber: String, options: ResolverResolveOptions) async throws -> HomeserverResolution {
        struct RequestBody: Encodable {
            let phone: String
            let country: String?
            let mccmnc: String?
            let carrier: String?
            let regionHint: String?
            let affiliations: [String]?
            let attributes: [String: String]?
            let routingClaims: ResolverRoutingClaimsEnvelope?
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
            let trace: ResolverDecisionTrace?
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
        guard httpResponse.statusCode == 200 else { throw ResolverError.server(status: httpResponse.statusCode) }

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
                                                                   region: ref.region))
    }
}
