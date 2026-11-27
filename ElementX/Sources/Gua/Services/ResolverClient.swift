//
// Copyright 2025 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

nonisolated struct ResolvedHomeserver: Equatable {
    let serverName: String
    let baseURL: String
    let masIssuer: String?
    let region: String?
}

nonisolated struct HomeserverResolution: Equatable {
    let exists: Bool
    let homeserver: ResolvedHomeserver
    /// Set only when `ResolveOptions.trace` was requested; for debugging, never shown in the UI.
    var trace: DecisionTrace?
    /// Absent from older resolvers, and from a current one when the roster changed during the request.
    var rosterVersion: Int64?
}

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

/// Opaque signed `gua-routing-claims.v1` envelope; pass it through unaltered.
struct RoutingClaimsEnvelope: Codable, Equatable {
    let schemaVersion: String
    let issuer: String
    let audience: String
    let issuedAt: String
    let expiresAt: String
    let nonce: String
    /// E.164 phone, signed and checked against the resolved phone, so an envelope cannot be replayed for another number.
    let subject: String
    let affiliations: [String]?
    let attributes: [String: String]?
    let signatures: [ClaimSignature]
}

struct ClaimSignature: Codable, Equatable {
    let keyId: String
    let signatureB64: String
}

nonisolated struct DecisionTrace: Decodable, Equatable {
    let source: String
    let rule: String
    let ruleId: String?
    let reason: String?
    let policyId: String?
    let policyVersion: Int64?
    let delegatedZoneId: String?
    let assignmentPolicy: String?
    let homeserverId: String?
    let rosterVersion: Int64?
}

/// Decodes only the fields federated user search reads.
struct FederationRosterServer: Decodable, Equatable {
    let serverName: String
    /// Absent means globally discoverable; interpreted by `RosterSearchVisibility`.
    let searchVisibility: String?
    /// Discovery groups compared against the searcher's own server's groups when the policy is `group`.
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
    case directoryUnavailable(retryAfter: TimeInterval?)
    case noPlacementAvailable
    case rateLimited(retryAfter: TimeInterval?)
    case temporarilyUnavailable(retryAfter: TimeInterval?)
    
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
        case .rateLimited: "The routing service is rate limiting requests."
        case .temporarilyUnavailable: "The routing service is temporarily unavailable."
        }
    }
    
    /// Shown on the phone-entry screen; `errorDescription` is for logs.
    var userFacingMessage: String {
        switch self {
        case .invalidPhone:
            L10n.screenPhoneLoginInvalidNumber
        case .invalidRoutingClaims:
            UntranslatedL10n.guaResolverClaimsInvalid
        case .noPlacementAvailable:
            UntranslatedL10n.guaResolverRegistrationClosed
        case let .rateLimited(retryAfter):
            Self.formattedWait(retryAfter).map { UntranslatedL10n.guaResolverRateLimitedRetryIn($0) } ?? UntranslatedL10n.guaResolverRateLimited
        case let .directoryUnavailable(retryAfter), let .temporarilyUnavailable(retryAfter):
            Self.formattedWait(retryAfter).map { UntranslatedL10n.guaResolverRoutingUnavailableRetryIn($0) } ?? UntranslatedL10n.guaResolverRoutingUnavailable
        case .server, .transport, .decoding, .malformedResponse, .invalidURL, .notConfigured:
            L10n.errorUnknown
        }
    }
    
    /// Waits of a minute or more round up to whole minutes, so the user is never told to retry early.
    static func formattedWait(_ retryAfter: TimeInterval?) -> String? {
        guard let seconds = retryAfter?.rounded(.up), seconds.isFinite, seconds >= 1 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: Bundle.guaAppLanguage)
        let formatter = DateComponentsFormatter()
        formatter.calendar = calendar
        formatter.unitsStyle = .full
        if seconds < 60 {
            formatter.allowedUnits = [.second]
            return formatter.string(from: seconds)
        }
        formatter.allowedUnits = [.minute]
        return formatter.string(from: (seconds / 60).rounded(.up) * 60)
    }
}

protocol ResolverClientProtocol: Sendable {
    /// The resolver does not verify ownership of the number.
    func resolve(phoneNumber: String) async throws -> HomeserverResolution
    
    /// Use `resolve(phoneNumber:)` unless there are verified identity claims to send.
    func resolve(phoneNumber: String, options: ResolveOptions) async throws -> HomeserverResolution
}

extension ResolverClientProtocol {
    /// Drops `options` for conformers that only implement `resolve(phoneNumber:)`.
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
        // Synthesized Encodable omits nil fields, so a plain resolve still sends the legacy `{"phone"}` body.
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
            let rosterVersion: Int64?
            let trace: DecisionTrace?
            
            private enum CodingKeys: String, CodingKey {
                case exists, homeserver, registerAt, rosterVersion, trace
            }
            
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                exists = try container.decode(Bool.self, forKey: .exists)
                homeserver = try container.decodeIfPresent(HomeserverRef.self, forKey: .homeserver)
                registerAt = try container.decodeIfPresent(HomeserverRef.self, forKey: .registerAt)
                // Read only by the report-only verifier; a malformed value must not fail sign-in.
                rosterVersion = try? container.decodeIfPresent(Int64.self, forKey: .rosterVersion)
                trace = try container.decodeIfPresent(DecisionTrace.self, forKey: .trace)
            }
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
            throw resolveError(response: httpResponse, body: data)
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
                                    trace: parsed.trace,
                                    rosterVersion: parsed.rosterVersion)
    }
    
    /// A 429 is rate limiting whatever its body: the ingress answers it in plain text.
    private func resolveError(response: HTTPURLResponse, body: Data) -> ResolverError {
        struct ProblemResponse: Decodable {
            let code: String?
            let message: String?
        }
        let status = response.statusCode
        let retryAfter = Self.retryAfter(of: response)
        if status == 429 {
            return .rateLimited(retryAfter: retryAfter)
        }
        return switch (try? decoder.decode(ProblemResponse.self, from: body))?.code {
        case "invalid_phone": .invalidPhone
        case "invalid_routing_claims": .invalidRoutingClaims
        case "directory_unavailable": .directoryUnavailable(retryAfter: retryAfter)
        case "no_placement_available": .noPlacementAvailable
        case _ where status == 503: .temporarilyUnavailable(retryAfter: retryAfter)
        default: .server(status: status)
        }
    }
    
    /// Measures an HTTP-date from the response's `Date` header when present, so client clock skew does not change the wait.
    static func retryAfter(of response: HTTPURLResponse, now: Date = .now) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces),
              !value.isEmpty else {
            return nil
        }
        if let seconds = Int(value) {
            return seconds >= 0 ? TimeInterval(seconds) : nil
        }
        guard let retryDate = httpDate(from: value) else { return nil }
        let reference = response.value(forHTTPHeaderField: "Date").flatMap(httpDate(from:)) ?? now
        let delay = retryDate.timeIntervalSince(reference)
        return delay > 0 ? delay : nil
    }
    
    /// RFC 9110 HTTP-date: IMF-fixdate plus the obsolete RFC 850 and asctime forms recipients must accept.
    private static func httpDate(from value: String) -> Date? {
        let normalized = value.split(separator: " ").joined(separator: " ")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: normalized) {
                return date
            }
        }
        return nil
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
