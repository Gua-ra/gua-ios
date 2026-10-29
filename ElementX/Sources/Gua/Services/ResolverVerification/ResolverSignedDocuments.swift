//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

// A `member` block is read strictly, because its signature must cover every field the reader uses; the rest is
// read leniently. Enum-valued fields are kept as served, so the signature over them decides an unknown value.

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
        entries = try container.decode([SignedRosterEntry].self, forKey: .entries)
        logCheckpoint = try container.decode(RosterLogCheckpoint.self, forKey: .logCheckpoint)
        authoritySignatures = try container.decode([RosterAuthoritySignature].self, forKey: .authoritySignatures)
    }

    var activeEntries: [SignedRosterEntry] {
        entries.filter(\.isActive)
    }
}

struct RosterLogCheckpoint: Codable, Equatable {
    let merkleRoot: String
    let size: Int

    private enum CodingKeys: String, CodingKey {
        case merkleRoot, size
    }
}

extension RosterLogCheckpoint {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        merkleRoot = try container.decode(String.self, forKey: .merkleRoot)
        size = try container.decodeSizeOrIndex(forKey: .size)
    }
}

struct RosterAuthoritySignature: Decodable {
    let authorityKeyId: String?
    let signatureB64: String?
}

struct SignedRosterEntry: Decodable {
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
    let id: String?
    let serverName: String?
    let baseUrl: String?
    let masIssuer: String?
    let region: String?
    let weight: Int32
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
        id = try container.decodeIfPresent(String.self, forKey: .id)
        serverName = try container.decodeIfPresent(String.self, forKey: .serverName)
        baseUrl = try container.decodeIfPresent(String.self, forKey: .baseUrl)
        masIssuer = try container.decodeIfPresent(String.self, forKey: .masIssuer)
        region = try container.decodeIfPresent(String.self, forKey: .region)
        weight = try container.decode(Int32.self, forKey: .weight)
        acceptsNew = try container.decode(Bool.self, forKey: .acceptsNew)
        signingKey = try container.decodeIfPresent(String.self, forKey: .signingKey)
        hasSearchVisibilityField = container.contains(.searchVisibility)
        searchVisibility = try container.decodeIfPresent(String.self, forKey: .searchVisibility) ?? "GLOBAL"
        searchGroups = try container.decodeIfPresent([String].self, forKey: .searchGroups) ?? []
    }

    /// Whether a `/resolve` answer names this homeserver: the same server name, base URL and auth issuer.
    func hasEndpoint(of answer: ResolvedHomeserver) -> Bool {
        serverName == answer.serverName && baseUrl == answer.baseURL && masIssuer == answer.masIssuer
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
    let priority: Int32

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
        priority = try container.decodeIfPresent(Int32.self, forKey: .priority) ?? 0
    }

    var isRemote: Bool {
        guard let remoteClaimUrl else { return false }
        return !remoteClaimUrl.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// The member-signed block, parsed strictly: an unknown field or a null at either level refuses the block.
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
        schema = try container.decodeStrictly(String.self, forKey: .schema)
        alg = try container.decodeStrictly(String.self, forKey: .alg)
        keyId = try container.decodeStrictly(String.self, forKey: .keyId)
        sequence = try container.decodeStrictly(Int64.self, forKey: .sequence) ?? 0
        notBefore = try container.decodeStrictly(String.self, forKey: .notBefore)
        notAfter = try container.decodeStrictly(String.self, forKey: .notAfter)
        signatures = try container.decodeStrictly([RosterMemberSignature].self, forKey: .signatures) ?? []
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
        keyId = try container.decodeStrictly(String.self, forKey: .keyId)
        signatureB64 = try container.decodeStrictly(String.self, forKey: .signatureB64)
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

private extension KeyedDecodingContainer {
    /// A field that may be absent but, when present, must have the type, so a null is refused.
    func decodeStrictly<Value: Decodable>(_ type: Value.Type, forKey key: Key) throws -> Value? {
        try contains(key) ? decode(type, forKey: key) : nil
    }

    func decodeSizeOrIndex(forKey key: Key) throws -> Int {
        let value = try decode(Int32.self, forKey: key)
        guard value >= 0 else { throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "does not fit in 31 bits") }
        return Int(value)
    }
}

// MARK: - Routing policy

/// An artifact in effect from `notBefore`, inclusive, until `expiresAt`, exclusive. An absent bound is open and a
/// bound that does not parse never holds.
protocol ResolverValidityWindow {
    var notBefore: String? { get }
    var expiresAt: String? { get }
}

extension ResolverValidityWindow {
    func isInEffect(atEpochMilliseconds now: Int64) -> Bool {
        // The signed bytes write a missing bound and one at the epoch alike, as 0, so both leave that side open.
        if let notBefore {
            guard let start = ResolverInstant(iso: notBefore)?.epochMilliseconds else { return false }
            if start != 0, now < start { return false }
        }
        if let expiresAt {
            guard let end = ResolverInstant(iso: expiresAt)?.epochMilliseconds else { return false }
            if end != 0, now >= end { return false }
        }
        return true
    }
}

struct RoutingPolicyBundle: Decodable, ResolverValidityWindow {
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

struct DelegationZone: Decodable, ResolverValidityWindow {
    let id: String?
    let scopeType: String?
    let scopeValue: String?
    let delegatedAuthority: String?
    let delegateKeyId: String?
    let delegatePublicKey: String?
    let allowedHomeserverIds: [String]?
    let notBefore: String?
    let expiresAt: String?
}

struct RoutingPolicyRule: Decodable {
    let id: String?
    let priority: Int32
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
        priority = try container.decodeIfPresent(Int32.self, forKey: .priority) ?? 0
        matchType = try container.decodeIfPresent(String.self, forKey: .matchType)
        matchValue = try container.decodeIfPresent(String.self, forKey: .matchValue)
        oidcIssuer = try container.decodeIfPresent(String.self, forKey: .oidcIssuer)
        oidcClaim = try container.decodeIfPresent(String.self, forKey: .oidcClaim)
        targetHomeserverId = try container.decodeIfPresent(String.self, forKey: .targetHomeserverId)
        delegatedZoneId = try container.decodeIfPresent(String.self, forKey: .delegatedZoneId)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        assignmentPolicy = try container.decodeIfPresent(String.self, forKey: .assignmentPolicy)
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
    let events: [TransparencyLogEvent]
}

struct TransparencyLogEvent: Decodable {
    let index: Int
    let type: String
    let homeserverId: String?
    let payloadHash: String
    let recordedAt: ResolverInstant

    private enum CodingKeys: String, CodingKey {
        case index, type, homeserverId, payloadHash, recordedAt
    }

    var isPolicyPublication: Bool {
        type == "POLICY_PUBLISH"
    }

    var leafHash: String {
        MerkleTree.leafHash(Array(MerkleTree.leafData(index: index, type: type, homeserverId: homeserverId, payloadHash: payloadHash,
                                                      recordedAtEpochMilliseconds: recordedAt.epochMilliseconds).utf8))
    }

    /// Whether this leaf publishes a later version of the served policy. A publication's subject, carried in
    /// `homeserverId`, is `<policyId>:v<version>`.
    func publishesLaterVersion(of served: ServedPolicy) -> Bool {
        guard isPolicyPublication, let subject = homeserverId, let separator = subject.range(of: ":v", options: .backwards),
              let version = Int64(subject[separator.upperBound...]) else {
            return false
        }
        return String(subject[..<separator.lowerBound]) == served.policyId && version > served.version
    }
}

extension TransparencyLogEvent {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decodeSizeOrIndex(forKey: .index)
        type = try container.decode(String.self, forKey: .type)
        homeserverId = try container.decodeIfPresent(String.self, forKey: .homeserverId)
        payloadHash = try container.decode(String.self, forKey: .payloadHash)
        // Every served event must be well formed, past the checkpoint too, even though only the signed ones are hashed.
        guard let recordedAt = try ResolverInstant(iso: container.decode(String.self, forKey: .recordedAt)) else {
            throw DecodingError.dataCorruptedError(forKey: .recordedAt, in: container, debugDescription: "not a resolver timestamp")
        }
        self.recordedAt = recordedAt
    }
}

/// A served policy bundle as its `POLICY_PUBLISH` leaf names it.
struct ServedPolicy {
    let policyId: String?
    let version: Int64
    /// SHA-256 of the bundle's canonical bytes, the leaf's payload hash.
    let contentHash: String
}

struct ConsistencyProofDocument: Decodable {
    let proof: [String]

    private enum CodingKeys: String, CodingKey {
        case proof
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        proof = try container.decode([String].self, forKey: .proof)
        guard proof.allSatisfy(Self.isHash) else {
            throw DecodingError.dataCorruptedError(forKey: .proof, in: container, debugDescription: "a proof hash is not 64 lowercase hex characters")
        }
    }

    private static func isHash(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0) }
    }
}
