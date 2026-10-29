//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import XCTest

/// The port against the resolver's golden vectors. The two files under `UnitTests/Resources` are byte-identical
/// copies of `docs/specs/gua-client-verification-v1-vectors.json` and `docs/specs/gua-lp-v1-vectors.json` in
/// gua-resolver; every section of both is walked and every assertion names the vector it belongs to.
final class ResolverVerificationVectorsTests: XCTestCase {
    private var vectors: JSONObject!
    private var lpVectors: JSONObject!

    /// The acceptance time the member entries are checked against: inside every window the vectors sign.
    private var now: Int64 = 0

    override func setUpWithError() throws {
        now = try XCTUnwrap(ResolverInstant(iso: "2026-10-27T00:00:00Z")).epochMilliseconds
        vectors = try JSONObject.load("gua-client-verification-v1-vectors.json")
        lpVectors = try JSONObject.load("gua-lp-v1-vectors.json")
    }

    // MARK: - Keys

    func testEveryKeyIsAnEd25519SPKIDocument() throws {
        for file in try [XCTUnwrap(vectors), XCTUnwrap(lpVectors)] {
            let keys = file.object("keys").dictionary
            XCTAssertFalse(keys.isEmpty, "the keys section is empty")
            for (name, key) in keys {
                let key = JSONObject(key)
                let spki = try XCTUnwrap(Data(base64Encoded: key.string("publicKeySpkiB64")), name)
                XCTAssertEqual(spki.count, 44, name)
                XCTAssertEqual(Array(spki.prefix(12)), ResolverVerificationCrypto.spkiPrefix, name)
                XCTAssertEqual(ResolverVerificationHex.string(Array(spki.suffix(32))), key.string("publicKeyHex"), name)
                let raw = try XCTUnwrap(ResolverVerificationCrypto.rawPublicKey(spkiBase64: key.string("publicKeySpkiB64")), name)
                XCTAssertEqual(ResolverVerificationHex.string(raw), key.string("publicKeyHex"), name)
            }
        }
    }

    // MARK: - Instants

    func testEveryInstantTruncatesToTheListedEpochMilliseconds() throws {
        for vector in vectors.section("instants") {
            let iso = vector.string("iso")
            let instant = try XCTUnwrap(ResolverInstant(iso: iso), iso)
            XCTAssertEqual(instant.epochMilliseconds, Int64(vector.string("epochMs")), iso)
        }
    }

    // MARK: - Rosters

    func testEveryRosterVectorReproducesItsBytesAndVerdict() throws {
        for vector in vectors.section("rosters") {
            let name = vector.string("name")
            let roster = try vector.decode(SignedRosterDocument.self, at: "roster")
            let form = try XCTUnwrap(CanonicalRoster.form(of: roster), name)
            XCTAssertEqual(form.rawValue, vector.string("form"), name)
            let canonical = try XCTUnwrap(CanonicalRoster.bytes(of: roster, form: form), name)
            XCTAssertEqual(String(bytes: canonical, encoding: .utf8), vector.string("canonicalUtf8"), name)
            XCTAssertEqual(ResolverVerificationHex.string(canonical), vector.string("canonicalHex"), name)
            XCTAssertEqual(ResolverVerificationCrypto.sha256Hex(canonical), vector.string("sha256Hex"), name)

            let count = Self.authorityCount(roster, canonical: canonical, vector: vector)
            XCTAssertEqual(count.valid, vector.int("validSignatures"), name)
            XCTAssertEqual(count.valid >= vector.int("threshold"), vector.bool("verified"), name)
        }
    }

    func testEveryRosterRejectionIsRefusedWithItsOutcome() throws {
        for vector in vectors.section("rosterRejections") {
            let name = vector.string("name")
            let roster = try vector.decode(SignedRosterDocument.self, at: "roster")
            XCTAssertFalse(vector.bool("verified"), name)
            guard let offeredForm = RosterForm(rawValue: vector.string("form")) else {
                XCTAssertNil(CanonicalRoster.form(of: roster), name)
                XCTAssertEqual(ResolverVerificationReport.RosterSignature.unverifiable(.mixedRosterForm).summary.code, vector.string("expectedOutcome"), name)
                continue
            }
            let canonical = try XCTUnwrap(CanonicalRoster.bytes(of: roster, form: offeredForm), name)
            XCTAssertEqual(ResolverVerificationHex.string(canonical), vector.string("canonicalHex"), name)
            let count = Self.authorityCount(roster, canonical: canonical, vector: vector)
            XCTAssertEqual(count.valid, vector.int("validSignatures"), name)
            let outcome: ResolverVerificationReport.RosterSignature = count.failureReason(threshold: vector.int("threshold")).map { .invalid($0) } ?? .valid
            XCTAssertEqual(outcome.summary.code, vector.string("expectedOutcome"), name)
            // The app follows the served JSON, so a roster that fails only under the other form verifies.
            let servedForm = try XCTUnwrap(CanonicalRoster.form(of: roster), name)
            if servedForm != offeredForm {
                let servedCanonical = try XCTUnwrap(CanonicalRoster.bytes(of: roster, form: servedForm), name)
                XCTAssertNil(Self.authorityCount(roster, canonical: servedCanonical, vector: vector).failureReason(threshold: vector.int("threshold")), name)
            }
        }
    }

    private static func authorityCount(_ roster: SignedRosterDocument, canonical: [UInt8], vector: JSONObject) -> ResolverSignatureCounter.Count {
        ResolverSignatureCounter.count(signatures: roster.authoritySignatures.map { ($0.authorityKeyId, $0.signatureB64) },
                                       over: canonical, keys: ResolverSignatureCounter.keys(vector.trustedKeys))
    }

    // MARK: - Transparency log

    func testTheLogVectorsReproduceLeavesRootsAndProofs() throws {
        let log = vectors.object("log")
        var leafHashes = [String]()
        for event in log.section("events") {
            let name = "event \(event.int("index"))"
            let recordedAt = try XCTUnwrap(ResolverInstant(iso: event.string("recordedAt")), name)
            let leafData = MerkleTree.leafData(index: Int64(event.int("index")), type: event.string("type"),
                                               homeserverId: event.stringIfPresent("homeserverId"),
                                               payloadHash: event.string("payloadHash"),
                                               recordedAtEpochMilliseconds: recordedAt.epochMilliseconds)
            XCTAssertEqual(leafData, event.string("leafDataUtf8"), name)
            let leafHash = MerkleTree.leafHash(Array(leafData.utf8))
            XCTAssertEqual(leafHash, event.string("leafHashHex"), name)
            leafHashes.append(leafHash)
        }
        for root in log.section("roots") {
            let size = root.int("size")
            XCTAssertEqual(MerkleTree.root(leafHashes: Array(leafHashes.prefix(size))), root.string("rootHex"), "root at size \(size)")
        }
        for proof in log.section("consistencyProofs") {
            let name = "consistency \(proof.int("first")),\(proof.int("second"))"
            XCTAssertTrue(proof.bool("valid"), name)
            XCTAssertTrue(MerkleTree.verifyConsistency(first: proof.int("first"), second: proof.int("second"),
                                                       oldRoot: proof.string("oldRootHex"), newRoot: proof.string("newRootHex"),
                                                       proof: proof.stringArray("proof")), name)
        }
        for proof in log.section("invalidConsistencyProofs") {
            let name = proof.string("name")
            XCTAssertFalse(proof.bool("valid"), name)
            XCTAssertFalse(MerkleTree.verifyConsistency(first: proof.int("first"), second: proof.int("second"),
                                                        oldRoot: proof.string("oldRootHex"), newRoot: proof.string("newRootHex"),
                                                        proof: proof.stringArray("proof")), name)
        }
    }

    // MARK: - Policies

    func testEveryPolicyVectorReproducesItsBytesAndVerdict() throws {
        for vector in vectors.section("policies") + vectors.section("policyRejections") {
            let name = vector.string("name")
            let bundle = try vector.decode(RoutingPolicyBundle.self, at: "bundle")
            let canonical = try XCTUnwrap(CanonicalRoutingPolicy.bytes(of: bundle), name)
            XCTAssertEqual(String(bytes: canonical, encoding: .utf8), vector.string("canonicalUtf8"), name)
            XCTAssertEqual(ResolverVerificationHex.string(canonical), vector.string("canonicalHex"), name)
            XCTAssertEqual(ResolverVerificationCrypto.sha256Hex(canonical), vector.string("sha256Hex"), name)
            for zone in vector.section("delegatedRules") {
                let delegated = CanonicalRoutingPolicy.delegatedRulesBytes(policyId: bundle.policyId, version: bundle.version,
                                                                           zoneId: zone.string("zoneId"), rules: bundle.rules)
                XCTAssertEqual(ResolverVerificationHex.string(delegated), zone.string("canonicalHex"), "\(name) \(zone.string("zoneId"))")
            }
            let count = RoutingPolicyVerifier.validSignatureCount(of: bundle, canonical: canonical,
                                                                  keys: ResolverSignatureCounter.keys(vector.trustedKeys))
            XCTAssertEqual(count.valid >= vector.int("threshold"), vector.bool("verified"), name)
            XCTAssertEqual(RoutingPolicyVerifier.delegateVerifiedZones(of: bundle), Set(vector.stringArray("delegateVerifiedZones")), name)
        }
    }

    func testEveryPolicyRejectionIsRefusedWithItsOutcome() throws {
        for vector in vectors.section("policyRejections") {
            let name = vector.string("name")
            let bundle = try vector.decode(RoutingPolicyBundle.self, at: "bundle")
            let canonical = try XCTUnwrap(CanonicalRoutingPolicy.bytes(of: bundle), name)
            let keys = ResolverSignatureCounter.keys(vector.trustedKeys)
            let failure = keys.isEmpty ? nil : RoutingPolicyVerifier.validSignatureCount(of: bundle, canonical: canonical, keys: keys)
                .failureReason(threshold: vector.int("threshold"))
            let outcome: ResolverVerificationReport.Policy = keys.isEmpty ? .unverifiable(.noPolicyKeys) : failure.map { .invalid($0) } ?? .valid
            XCTAssertFalse(vector.bool("verified"), name)
            XCTAssertEqual(outcome.summary.code, vector.string("expectedOutcome"), name)
        }
    }

    func testEveryPolicyValidityEdgeIsInEffectAsListed() throws {
        let policies = vectors.byRef("policies")
        for vector in vectors.section("policyValidity") {
            let name = vector.string("name")
            let bundle = try XCTUnwrap(policies[vector.string("policyRef")], name).decode(RoutingPolicyBundle.self, at: "bundle")
            let evaluatedAt = try XCTUnwrap(ResolverInstant(iso: vector.string("evaluatedAt")), name)
            XCTAssertEqual(bundle.isInEffect(atEpochMilliseconds: evaluatedAt.epochMilliseconds), vector.bool("inEffect"), name)
        }
    }

    func testEveryPolicyLogCaseGivesItsOutcome() throws {
        let events = try vectors.object("log").decode([TransparencyLogEvent].self, at: "events")
        for vector in vectors.section("policyLog") {
            let name = vector.string("name")
            let served = vector.objectIfPresent("servedPolicy").map { policy in
                ServedPolicy(policyId: policy.stringIfPresent("policyId"), version: Int64(policy.int("version")), contentHash: policy.string("sha256Hex"))
            }
            let checkpoint = vector.object("checkpoint")
            let outcome = ResolverVerifier.logOutcome(for: served, checkpoint: RosterLogCheckpoint(merkleRoot: checkpoint.string("rootHex"), size: checkpoint.int("size")),
                                                      events: events)
            XCTAssertEqual(outcome.summary.code, vector.string("expected"), name)
        }
    }

    // MARK: - Placements

    func testEveryPlacementVectorReproducesTheReferenceDecision() throws {
        let rosters = vectors.byRef("rosters")
        let policies = vectors.byRef("policies")
        for vector in vectors.section("placements") {
            let name = vector.string("name")
            let roster = try XCTUnwrap(rosters[vector.string("rosterRef")], name).decode(SignedRosterDocument.self, at: "roster")
            var policy: VerifiedRoutingPolicy?
            if let policyRef = vector.stringIfPresent("policyRef") {
                let policyVector = try XCTUnwrap(policies[policyRef], name)
                let bundle = try policyVector.decode(RoutingPolicyBundle.self, at: "bundle")
                let canonical = try XCTUnwrap(CanonicalRoutingPolicy.bytes(of: bundle), name)
                let count = RoutingPolicyVerifier.validSignatureCount(of: bundle, canonical: canonical,
                                                                      keys: ResolverSignatureCounter.keys(policyVector.trustedKeys))
                XCTAssertGreaterThanOrEqual(count.valid, policyVector.int("threshold"), name)
                policy = VerifiedRoutingPolicy(bundle: bundle, delegateVerifiedZones: RoutingPolicyVerifier.delegateVerifiedZones(of: bundle))
            }
            // Affiliations and attributes stated without proof are left out, as the server leaves them out.
            let contextJSON = vector.object("context")
            let context = PlacementContext(phone: contextJSON.stringIfPresent("phone"),
                                           country: contextJSON.stringIfPresent("country"),
                                           mccmnc: contextJSON.stringIfPresent("mccmnc"),
                                           carrier: contextJSON.stringIfPresent("carrier"),
                                           regionHint: contextJSON.stringIfPresent("regionHint"))
            let evaluatedAt = try XCTUnwrap(ResolverInstant(iso: vector.string("evaluatedAt")), name).epochMilliseconds
            let decision = try XCTUnwrap(PlacementReproducer.decide(context: context, roster: roster, policy: policy,
                                                                    nowEpochMilliseconds: evaluatedAt), name)
            let reference = Self.reference(of: decision)
            XCTAssertEqual(decision.homeserver.id, vector.string("expectedHomeserverId"), name)
            XCTAssertEqual(reference.rule, vector.string("expectedRule"), name)
            XCTAssertEqual(reference.ruleId, vector.string("expectedRuleId"), name)
            let unsignedRuleAbove = policy.map {
                PlacementReproducer.unsignedRuleRanksAbove(decision, context: context, policy: $0, nowEpochMilliseconds: evaluatedAt)
            } ?? false
            XCTAssertEqual(unsignedRuleAbove, vector.bool("unsignedRuleAbove"), name)
            if let fallback = vector.objectIfPresent("fallback") {
                XCTAssertEqual(context.canonicalRoutingKey, fallback.string("routingKeyUtf8"), name)
                let candidates = PlacementReproducer.fallbackCandidates(in: roster)
                XCTAssertEqual(candidates.map(\.id), fallback.array("candidates").map { JSONObject($0).string("id") }, name)
                XCTAssertEqual(candidates.map { Int($0.weight) }, fallback.array("candidates").map { JSONObject($0).int("weight") }, name)
                XCTAssertEqual(PlacementReproducer.stableHash(context: context, rosterVersion: roster.version, candidates: candidates),
                               Int32(fallback.int("stableHash")), name)
                XCTAssertEqual(roster.version, Int64(fallback.int("rosterVersion")), name)
            }
        }
    }

    /// The reference verifier's name and id for the rule that decided.
    private static func reference(of decision: PlacementDecision) -> (rule: String, ruleId: String) {
        switch decision.rule {
        case .policy(let rule): ("PolicyRoutingRule", rule.id ?? "")
        case .rosterClaim(let priority): ("ClaimRule", "roster-claim:\(decision.homeserver.id):\(priority)")
        case .weightedFallback: ("WeightedFallbackRule", "weighted-fallback")
        }
    }

    // MARK: - Resolve answers

    func testEveryResolveAnswerVectorLocatesAsExpected() throws {
        let rosters = vectors.byRef("rosters")
        for vector in vectors.section("resolveAnswers") {
            let name = vector.string("name")
            let roster = try XCTUnwrap(rosters[vector.string("rosterRef")], name).decode(SignedRosterDocument.self, at: "roster")
            let answer = vector.object("answer")
            let located = ResolverVerifier.locate(ResolvedHomeserver(serverName: answer.string("serverName"), baseURL: answer.string("baseUrl"),
                                                                     masIssuer: answer.stringIfPresent("masIssuer"), region: nil),
                                                  in: roster)
            XCTAssertEqual(located.match.summary.code, vector.string("expected"), name)
            XCTAssertEqual(located.entry?.homeserver.id, vector.stringIfPresent("expectedEntryId"), name)
        }
    }

    // MARK: - gua-lp.v1 primitives

    func testEveryPrimitiveEncodesToItsBytes() throws {
        for vector in lpVectors.section("primitives") {
            let name = vector.string("name")
            var encoder = GuaLPEncoder()
            switch vector.string("type") {
            case "string": encoder.string(vector.string("value"))
            case "int64": try encoder.int64(XCTUnwrap(Int64(vector.string("value")), name))
            case "bool": encoder.bool(vector.bool("value"))
            case "optionalString": encoder.optionalString(vector.stringIfPresent("value"))
            case "stringSet": try encoder.stringSet(vector.stringArray("value"))
            case "stringList": encoder.stringList(vector.stringArray("value"))
            case "enum": encoder.enumName(vector.string("value"))
            default: XCTFail("unknown primitive type in \(name)")
            }
            XCTAssertEqual(ResolverVerificationHex.string(encoder.bytes), vector.string("hex"), name)
        }
    }

    // MARK: - Member entries

    func testEveryMemberEntryReproducesItsBytesAndVerifies() throws {
        for vector in lpVectors.section("memberEntries") {
            let name = vector.string("name")
            let homeserver = try vector.decode(RosterHomeserver.self, at: "homeserver")
            let member = try vector.decode(RosterMemberAttestation.self, at: "member")
            let notBefore = try XCTUnwrap(ResolverInstant(iso: XCTUnwrap(member.notBefore)), name)
            let notAfter = try XCTUnwrap(ResolverInstant(iso: XCTUnwrap(member.notAfter)), name)
            XCTAssertEqual(notBefore.epochMilliseconds, Int64(vector.int("notBeforeEpochMs")), name)
            XCTAssertEqual(notAfter.epochMilliseconds, Int64(vector.int("notAfterEpochMs")), name)
            let canonical = try CanonicalMemberEntry.bytes(homeserver: homeserver, member: member,
                                                           notBefore: notBefore.epochMilliseconds, notAfter: notAfter.epochMilliseconds)
            XCTAssertEqual(ResolverVerificationHex.string(canonical), vector.string("canonicalHex"), name)
            XCTAssertEqual(ResolverVerificationCrypto.sha256Hex(canonical), vector.string("sha256Hex"), name)
            XCTAssertEqual(MemberEntryVerifier.verify(homeserver: homeserver, member: member, atEpochMilliseconds: now), .valid, name)
        }
    }

    func testEveryMemberEntryRejectionIsRefused() throws {
        // A rotation can only be refused against an entry accepted earlier, and the app keeps none.
        for vector in lpVectors.section("rejections") where vector.objectIfPresent("previous") == nil {
            let name = vector.string("name")
            let homeserver = try vector.decode(RosterHomeserver.self, at: "homeserver")
            guard let member = try? vector.decode(RosterMemberAttestation.self, at: "member") else {
                // Only the vector carrying an unknown field is refused by the strict reader; every other block decodes.
                XCTAssertTrue(name.contains("unknown field"), "\(name): the member block should decode")
                continue
            }
            let outcome = MemberEntryVerifier.verify(homeserver: homeserver, member: member, atEpochMilliseconds: now)
            guard case .invalid = outcome else {
                XCTFail("\(name): expected the entry to be refused, got \(outcome)")
                continue
            }
        }
    }
}

// MARK: - Vector access

/// A thin reader over the vector files' JSON, kept untyped so every section is walked as the file lays it out.
private struct JSONObject {
    let dictionary: [String: Any]

    init(_ any: Any) {
        dictionary = any as? [String: Any] ?? [:]
    }

    static func load(_ resource: String) throws -> JSONObject {
        let url = try XCTUnwrap(Bundle(for: ResolverVerificationVectorsTests.self).url(forResource: resource, withExtension: nil),
                                "\(resource) is missing from the test bundle.")
        return try JSONObject(JSONSerialization.jsonObject(with: Data(contentsOf: url)))
    }

    func object(_ key: String) -> JSONObject {
        JSONObject(dictionary[key] as Any)
    }

    func objectIfPresent(_ key: String) -> JSONObject? {
        dictionary[key] is [String: Any] ? object(key) : nil
    }

    func array(_ key: String) -> [Any] {
        dictionary[key] as? [Any] ?? []
    }

    func string(_ key: String) -> String {
        dictionary[key] as? String ?? ""
    }

    func stringIfPresent(_ key: String) -> String? {
        dictionary[key] as? String
    }

    func stringArray(_ key: String) -> [String] {
        dictionary[key] as? [String] ?? []
    }

    func stringArrayIfPresent(_ key: String) -> [String]? {
        dictionary[key] as? [String]
    }

    func stringDictionaryIfPresent(_ key: String) -> [String: String]? {
        dictionary[key] as? [String: String]
    }

    func int(_ key: String) -> Int {
        (dictionary[key] as? NSNumber)?.intValue ?? Int(string(key)) ?? 0
    }

    func bool(_ key: String) -> Bool {
        dictionary[key] as? Bool ?? false
    }

    func boolIfPresent(_ key: String) -> Bool? {
        dictionary[key] as? Bool
    }

    /// A section as objects. An empty section fails, so a renamed or dropped key cannot pass silently.
    func section(_ key: String, file: StaticString = #filePath, line: UInt = #line) -> [JSONObject] {
        let items = array(key).map(JSONObject.init)
        XCTAssertFalse(items.isEmpty, "the \(key) section is empty", file: file, line: line)
        return items
    }

    /// A section's objects by their `ref`, the key vectors join on.
    func byRef(_ key: String) -> [String: JSONObject] {
        Dictionary(section(key).compactMap { vector in vector.stringIfPresent("ref").map { ($0, vector) } }) { first, _ in first }
    }

    var trustedKeys: [ResolverTrustedKey] {
        array("trustedKeys").map(JSONObject.init).map { ResolverTrustedKey(id: $0.string("id"), publicKey: $0.string("publicKeySpkiB64")) }
    }

    /// Re-serializes a sub-object and decodes it the way the verifier decodes a served document.
    func decode<T: Decodable>(_ type: T.Type, at key: String) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: dictionary[key] as Any)
        return try JSONDecoder().decode(type, from: data)
    }
}
