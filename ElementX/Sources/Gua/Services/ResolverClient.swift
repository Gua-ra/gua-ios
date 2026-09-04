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
    /// Why the resolver decided what it did. Present only when the caller asked for a trace
    /// (`ResolveOptions.trace`); for debug and support tooling, never shown in the UI.
    var trace: DecisionTrace?
}

/// Optional `POST /resolve` request fields of the resolver v1 contract. Every field is omitted from the
/// JSON body when nil, so a plain resolve still sends the legacy `{"phone"}` body unchanged.
/// Android counterpart: `ResolverResolveOptions`.
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

/// Signed claims from the identity layer transported to the resolver for routing decisions
/// (schema `gua-routing-claims.v1`). The client is a courier only: it never mints or alters an
/// envelope, and the resolver trusts its contents solely after signature, audience, expiry and
/// subject-binding verification. Android counterpart: `ResolverRoutingClaimsEnvelope`.
struct RoutingClaimsEnvelope: Codable, Equatable {
    let schemaVersion: String
    let issuer: String
    let audience: String
    let issuedAt: String
    let expiresAt: String
    let nonce: String
    /// The E.164 phone this envelope was issued for. The resolver rejects an envelope whose subject
    /// does not match the resolved phone, and the subject is part of the signed canonical bytes, so
    /// a captured envelope cannot be replayed against another number.
    let subject: String
    let affiliations: [String]?
    let attributes: [String: String]?
    let signatures: [ClaimSignature]
}

/// One signature over a routing-claims envelope's canonical bytes.
struct ClaimSignature: Codable, Equatable {
    let keyId: String
    let signatureB64: String
}

/// The resolver's explanation of a routing decision, returned when `ResolveOptions.trace` is set.
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
    /// The roster version the decision was made against; what a verifying client pins.
    let rosterVersion: Int64?
}

/// One homeserver in the resolver's signed federation roster (`GET /roster`). Only the fields
/// federated user search consumes are decoded; the rest of the entry (keys, weights, …) is ignored.
struct FederationRosterServer: Decodable, Equatable {
    let serverName: String
    /// Raw bare-handle discoverability policy; absent means globally discoverable.
    /// Interpreted by `RosterSearchVisibility`.
    let searchVisibility: String?
    /// Discovery groups compared against the searcher's own server's groups when the policy is `group`.
    let searchGroups: [String]?
}

/// A roster entry: a homeserver plus its membership status in the federation.
struct FederationRosterEntry: Decodable, Equatable {
    let homeserver: FederationRosterServer
    let status: String

    var isActive: Bool {
        status == "ACTIVE"
    }
}

/// The resolver's view of the federation: every homeserver it routes to.
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

    // Typed problem codes from the resolver's error body `{code, message}`; anything unrecognized
    // stays a plain `.server(status:)`. Mirrors how `IdentityServiceClient` maps its `code` field.

    /// The resolver rejected the phone as not valid E.164 (`code: "invalid_phone"`, HTTP 400).
    case invalidPhone
    /// The signed routing-claims envelope failed verification (`code: "invalid_routing_claims"`, HTTP 400).
    case invalidRoutingClaims
    /// The routing directory is temporarily unavailable (`code: "directory_unavailable"`, HTTP 503).
    case directoryUnavailable
    /// No homeserver is currently accepting new accounts (`code: "no_placement_available"`, HTTP 503).
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

    /// A short, user-facing message for the phone-entry screen. `errorDescription` stays technical for
    /// logs; this is what the user actually reads. A known problem code gets its own copy; a plain 4xx
    /// means the number we sent was rejected as invalid (the user can fix it); anything else is a
    /// service/network problem (retry).
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
    /// Resolve a verified phone number to the homeserver it belongs to (or should be created on).
    func resolve(phoneNumber: String) async throws -> HomeserverResolution

    /// Resolve with the additive v1 contract fields (carrier and geo hints, routing claims, trace).
    /// Existing callers should keep using `resolve(phoneNumber:)` until they have verified identity
    /// claims to transport.
    func resolve(phoneNumber: String, options: ResolveOptions) async throws -> HomeserverResolution
}

extension ResolverClientProtocol {
    /// Default so existing conformers keep compiling: without an implementation of the richer call,
    /// the options are dropped and the plain resolve runs. Mirrors Android's `ResolverClient`.
    func resolve(phoneNumber: String, options: ResolveOptions) async throws -> HomeserverResolution {
        try await resolve(phoneNumber: phoneNumber)
    }
}

/// The slice of the resolver that federated user search needs: the roster of federation homeservers.
protocol FederationRosterFetching: Sendable {
    func fetchRoster() async throws -> FederationRoster
}

/// Talks to the Gua resolver — the federation front door. `POST /resolve` maps a phone number to a
/// homeserver, so the client never hardcodes one; `GET /roster` lists the federation's homeservers so
/// bare-handle search can fan out across them. See `gua-resolver`.
final class ResolverClient: ResolverClientProtocol, FederationRosterFetching {
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
        try await resolve(phoneNumber: phoneNumber, options: ResolveOptions())
    }

    func resolve(phoneNumber: String, options: ResolveOptions) async throws -> HomeserverResolution {
        // Optional fields are omitted when nil (synthesized Encodable uses encodeIfPresent), so a
        // plain resolve keeps sending the legacy `{"phone"}` body byte for byte.
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

    /// Map a non-success `/resolve` response to a typed error. The resolver's error body is
    /// `{code, message}` (its `ProblemResponse`); a recognized code produces its dedicated case so the
    /// phone-entry screen can show distinct human copy, anything else stays a plain server error.
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
