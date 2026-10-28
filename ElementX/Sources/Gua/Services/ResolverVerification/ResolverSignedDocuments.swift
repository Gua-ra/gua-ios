//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

// The documents the verifier fetches, decoded in full. The roster and the policy are read leniently at the
// document level (unknown fields ignored); a `member` block is read strictly, because a signature must
// never cover fewer fields than the reader goes on to use.

// MARK: - Roster

struct SignedRosterDocument: Decodable {
    let version: Int64
    let issuedAt: String
    let entries: [SignedRosterEntry]
    let logCheckpoint: RosterLogCheckpoint
    let authoritySignatures: [RosterAuthoritySignature]

    private enum CodingKeys: String, CodingKey {
        case version, issuedAt, entries, logCheckpoint, authoritySignatures
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int64.self, forKey: .version)
        issuedAt = try container.decode(String.self, forKey: .issuedAt)
        entries = try container.decodeIfPresent([SignedRosterEntry].self, forKey: .entries) ?? []
        logCheckpoint = try container.decode(RosterLogCheckpoint.self, forKey: .logCheckpoint)
        authoritySignatures = try container.decodeIfPresent([RosterAuthoritySignature].self, forKey: .authoritySignatures) ?? []
    }

    var activeEntries: [SignedRosterEntry] {
        entries.filter(\.isActive)
    }
}

struct RosterLogCheckpoint: Codable, Equatable {
    let merkleRoot: String
    let size: Int64
}

struct RosterAuthoritySignature: Decodable {
    let authorityKeyId: String?
    let signatureB64: String?
}

struct SignedRosterEntry: Decodable {
    static let statuses: Set = ["ACTIVE", "SUSPENDED", "REVOKED", "PENDING"]

    let homeserver: RosterHomeserver
    let claims: [RosterClaimPredicate]
    let admittedAt: String?
    let status: String
    let member: RosterMemberAttestation?
    /// A `member` block that was present and did not parse strictly. The entry's attestation is refused.
    let memberIsMalformed: Bool

    private enum CodingKeys: String, CodingKey {
        case homeserver, claims, admittedAt, status, member
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        homeserver = try container.decode(RosterHomeserver.self, forKey: .homeserver)
        claims = try container.decodeIfPresent([RosterClaimPredicate].self, forKey: .claims) ?? []
        admittedAt = try container.decodeIfPresent(String.self, forKey: .admittedAt)
        status = try container.decode(String.self, forKey: .status)
        guard Self.statuses.contains(status) else {
            throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "unknown status")
        }
        if container.contains(.member), try !container.decodeNil(forKey: .member) {
            let parsed = try? container.decode(RosterMemberAttestation.self, forKey: .member)
            member = parsed
            memberIsMalformed = parsed == nil
        } else {
            member = nil
            memberIsMalformed = false
        }
    }

    var isActive: Bool {
        status == "ACTIVE"
    }
}

struct RosterHomeserver: Decodable {
    static let visibilities: Set = ["GLOBAL", "SERVER", "GROUP"]

    let id: String
    let serverName: String
    let baseUrl: String
    let masIssuer: String?
    let region: String?
    let weight: Int
    let acceptsNew: Bool
    let signingKey: String?
    /// Whether the served JSON carried `searchVisibility` at all, which selects the roster form.
    let hasSearchVisibilityField: Bool
    let searchVisibility: String
    let searchGroups: [String]

    private enum CodingKeys: String, CodingKey {
        case id, serverName, baseUrl, masIssuer, region, weight, acceptsNew, signingKey, searchVisibility, searchGroups
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        serverName = try container.decode(String.self, forKey: .serverName)
        baseUrl = try container.decode(String.self, forKey: .baseUrl)
        masIssuer = try container.decodeIfPresent(String.self, forKey: .masIssuer)
        region = try container.decodeIfPresent(String.self, forKey: .region)
        weight = try container.decodeIfPresent(Int.self, forKey: .weight) ?? 0
        acceptsNew = try container.decodeIfPresent(Bool.self, forKey: .acceptsNew) ?? false
        signingKey = try container.decodeIfPresent(String.self, forKey: .signingKey)
        hasSearchVisibilityField = container.contains(.searchVisibility)
        searchVisibility = try container.decodeIfPresent(String.self, forKey: .searchVisibility) ?? "GLOBAL"
        guard Self.visibilities.contains(searchVisibility) else {
            throw DecodingError.dataCorruptedError(forKey: .searchVisibility, in: container, debugDescription: "unknown visibility")
        }
        searchGroups = try container.decodeIfPresent([String].self, forKey: .searchGroups) ?? []
    }

    init(id: String, serverName: String, baseUrl: String, masIssuer: String?, region: String?, weight: Int, acceptsNew: Bool,
         signingKey: String?, searchVisibility: String?, searchGroups: [String]?) {
        self.id = id
        self.serverName = serverName
        self.baseUrl = baseUrl
        self.masIssuer = masIssuer
        self.region = region
        self.weight = weight
        self.acceptsNew = acceptsNew
        self.signingKey = signingKey
        hasSearchVisibilityField = searchVisibility != nil
        self.searchVisibility = searchVisibility ?? "GLOBAL"
        self.searchGroups = searchGroups ?? []
    }
}

struct RosterClaimPredicate: Decodable {
    let country: String?
    let mccmnc: String?
    let carrier: String?
    let phonePrefixes: [String]?
    let affiliation: String?
    let attributeMatch: [String: String]?
    let remoteClaimUrl: String?
    let priority: Int

    private enum CodingKeys: String, CodingKey {
        case country, mccmnc, carrier, phonePrefixes, affiliation, attributeMatch, remoteClaimUrl, priority
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        country = try container.decodeIfPresent(String.self, forKey: .country)
        mccmnc = try container.decodeIfPresent(String.self, forKey: .mccmnc)
        carrier = try container.decodeIfPresent(String.self, forKey: .carrier)
        phonePrefixes = try container.decodeIfPresent([String].self, forKey: .phonePrefixes)
        affiliation = try container.decodeIfPresent(String.self, forKey: .affiliation)
        attributeMatch = try container.decodeIfPresent([String: String].self, forKey: .attributeMatch)
        remoteClaimUrl = try container.decodeIfPresent(String.self, forKey: .remoteClaimUrl)
        priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? 0
    }

    var isRemote: Bool {
        guard let remoteClaimUrl else { return false }
        return !remoteClaimUrl.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// The member-signed block, parsed strictly: an unknown field at either level refuses the block.
struct RosterMemberAttestation: Decodable {
    let schema: String?
    let alg: String?
    let keyId: String?
    let sequence: Int64
    let notBefore: String?
    let notAfter: String?
    let signatures: [RosterMemberSignature]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schema, alg, keyId, sequence, notBefore, notAfter, signatures
    }

    init(from decoder: Decoder) throws {
        try StrictKeys.check(decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(String.self, forKey: .schema)
        alg = try container.decodeIfPresent(String.self, forKey: .alg)
        keyId = try container.decodeIfPresent(String.self, forKey: .keyId)
        if container.contains(.sequence) {
            sequence = try container.decode(Int64.self, forKey: .sequence)
        } else {
            sequence = 0
        }
        notBefore = try container.decodeIfPresent(String.self, forKey: .notBefore)
        notAfter = try container.decodeIfPresent(String.self, forKey: .notAfter)
        signatures = try container.decodeIfPresent([RosterMemberSignature].self, forKey: .signatures) ?? []
    }
}

struct RosterMemberSignature: Decodable {
    let keyId: String?
    let signatureB64: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case keyId, signatureB64
    }

    init(from decoder: Decoder) throws {
        try StrictKeys.check(decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyId = try container.decodeIfPresent(String.self, forKey: .keyId)
        signatureB64 = try container.decodeIfPresent(String.self, forKey: .signatureB64)
    }
}

private enum StrictKeys {
    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? {
            nil
        }

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }
    }

    static func check<Allowed: CodingKey & CaseIterable>(_ decoder: Decoder, allowed: Allowed.Type) throws {
        let present = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
        let known = Set(Allowed.allCases.map(\.stringValue))
        if let unknown = present.first(where: { !known.contains($0) }) {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown field \(unknown)"))
        }
    }
}

// MARK: - Routing policy

struct RoutingPolicyBundle: Decodable {
    let schemaVersion: String?
    let policyId: String?
    let version: Int64
    let issuedAt: String?
    let notBefore: String?
    let expiresAt: String?
    let delegationZones: [DelegationZone]
    let rules: [RoutingPolicyRule]
    let fallback: FallbackStrategy?
    let signatures: [PolicySignature]
    let delegateSignatures: [DelegateSignature]

    struct FallbackStrategy: Decodable {
        let type: String?
        let enabled: Bool

        private enum CodingKeys: String, CodingKey {
            case type, enabled
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        }
    }

    struct PolicySignature: Decodable {
        let authorityKeyId: String?
        let signatureB64: String?
    }

    struct DelegateSignature: Decodable {
        let zoneId: String?
        let delegateKeyId: String?
        let signatureB64: String?
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, policyId, version, issuedAt, notBefore, expiresAt, delegationZones, rules, fallback, signatures, delegateSignatures
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(String.self, forKey: .schemaVersion)
        policyId = try container.decodeIfPresent(String.self, forKey: .policyId)
        version = try container.decodeIfPresent(Int64.self, forKey: .version) ?? 0
        issuedAt = try container.decodeIfPresent(String.self, forKey: .issuedAt)
        notBefore = try container.decodeIfPresent(String.self, forKey: .notBefore)
        expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt)
        delegationZones = try container.decodeIfPresent([DelegationZone].self, forKey: .delegationZones) ?? []
        rules = try container.decodeIfPresent([RoutingPolicyRule].self, forKey: .rules) ?? []
        fallback = try container.decodeIfPresent(FallbackStrategy.self, forKey: .fallback)
        signatures = try container.decodeIfPresent([PolicySignature].self, forKey: .signatures) ?? []
        delegateSignatures = try container.decodeIfPresent([DelegateSignature].self, forKey: .delegateSignatures) ?? []
    }
}

struct DelegationZone: Decodable {
    static let scopeTypes: Set = ["PHONE_PREFIX", "INSTITUTION_DOMAIN", "OIDC_ISSUER", "ATTRIBUTE"]

    let id: String?
    let scopeType: String?
    let scopeValue: String?
    let delegatedAuthority: String?
    let delegateKeyId: String?
    let delegatePublicKey: String?
    let allowedHomeserverIds: [String]?
    let notBefore: String?
    let expiresAt: String?

    private enum CodingKeys: String, CodingKey {
        case id, scopeType, scopeValue, delegatedAuthority, delegateKeyId, delegatePublicKey, allowedHomeserverIds, notBefore, expiresAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        scopeType = try container.decodeIfPresent(String.self, forKey: .scopeType)
        if let scopeType, !Self.scopeTypes.contains(scopeType) {
            throw DecodingError.dataCorruptedError(forKey: .scopeType, in: container, debugDescription: "unknown scope type")
        }
        scopeValue = try container.decodeIfPresent(String.self, forKey: .scopeValue)
        delegatedAuthority = try container.decodeIfPresent(String.self, forKey: .delegatedAuthority)
        delegateKeyId = try container.decodeIfPresent(String.self, forKey: .delegateKeyId)
        delegatePublicKey = try container.decodeIfPresent(String.self, forKey: .delegatePublicKey)
        allowedHomeserverIds = try container.decodeIfPresent([String].self, forKey: .allowedHomeserverIds)
        notBefore = try container.decodeIfPresent(String.self, forKey: .notBefore)
        expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt)
    }
}

struct RoutingPolicyRule: Decodable {
    static let matchTypes: Set = ["PHONE_PREFIX", "INSTITUTION_DOMAIN", "OIDC_CLAIM"]
    static let assignmentPolicies: Set = ["PORTABLE", "REQUIRES_CONFIRMATION", "LOCKED_BY_POLICY"]

    let id: String?
    let priority: Int
    let matchType: String?
    let matchValue: String?
    let oidcIssuer: String?
    let oidcClaim: String?
    let targetHomeserverId: String?
    let delegatedZoneId: String?
    let reason: String?
    let assignmentPolicy: String?
    let enabled: Bool?

    private enum CodingKeys: String, CodingKey {
        case id, priority, matchType, matchValue, oidcIssuer, oidcClaim, targetHomeserverId, delegatedZoneId, reason, assignmentPolicy, enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        matchType = try container.decodeIfPresent(String.self, forKey: .matchType)
        if let matchType, !Self.matchTypes.contains(matchType) {
            throw DecodingError.dataCorruptedError(forKey: .matchType, in: container, debugDescription: "unknown match type")
        }
        matchValue = try container.decodeIfPresent(String.self, forKey: .matchValue)
        oidcIssuer = try container.decodeIfPresent(String.self, forKey: .oidcIssuer)
        oidcClaim = try container.decodeIfPresent(String.self, forKey: .oidcClaim)
        targetHomeserverId = try container.decodeIfPresent(String.self, forKey: .targetHomeserverId)
        delegatedZoneId = try container.decodeIfPresent(String.self, forKey: .delegatedZoneId)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        assignmentPolicy = try container.decodeIfPresent(String.self, forKey: .assignmentPolicy)
        if let assignmentPolicy, !Self.assignmentPolicies.contains(assignmentPolicy) {
            throw DecodingError.dataCorruptedError(forKey: .assignmentPolicy, in: container, debugDescription: "unknown assignment policy")
        }
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
    }

    var isEnabled: Bool {
        enabled ?? true
    }

    var effectiveAssignmentPolicy: String {
        assignmentPolicy ?? "PORTABLE"
    }
}

// MARK: - Transparency log

struct TransparencyLogDocument: Decodable {
    let head: RosterLogCheckpoint?
    let events: [TransparencyLogEvent]
}

struct TransparencyLogEvent: Decodable {
    let index: Int64
    let type: String
    let homeserverId: String?
    let payloadHash: String
    let recordedAt: String
}

struct ConsistencyProofDocument: Decodable {
    let first: Int
    let second: Int
    let proof: [String]
}
