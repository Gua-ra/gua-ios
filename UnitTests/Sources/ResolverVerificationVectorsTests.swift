//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

/// The vector files are byte-identical copies of gua-resolver's `docs/specs`.
final class ResolverVerificationVectorsTests {
    private var vectors: JSONObject!
    private var lpVectors: JSONObject!
    
    /// A moment inside every validity window the vectors sign.
    private var now: Int64 = 0
    
    init() throws {
        now = try #require(ResolverInstant(iso: "2026-10-27T00:00:00Z")).epochMilliseconds
        vectors = try JSONObject.load("gua-client-verification-v1-vectors.json")
        lpVectors = try JSONObject.load("gua-lp-v1-vectors.json")
    }
    
    @Test
    func everyKeyIsAnEd25519SPKIDocument() throws {
        for file in try [#require(vectors), #require(lpVectors)] {
            let keys = file.object("keys").dictionary
            #expect(!keys.isEmpty, "the keys section is empty")
            for (name, key) in keys {
                let key = JSONObject(key)
                let spki = try #require(Data(base64Encoded: key.string("publicKeySpkiB64")), Comment(rawValue: name))
                #expect(spki.count == 44, Comment(rawValue: name))
                #expect(Array(spki.prefix(12)) == ResolverVerificationCrypto.spkiPrefix, Comment(rawValue: name))
                #expect(ResolverVerificationHex.string(Array(spki.suffix(32))) == key.string("publicKeyHex"), Comment(rawValue: name))
                let raw = try #require(ResolverVerificationCrypto.rawPublicKey(spkiBase64: key.string("publicKeySpkiB64")), Comment(rawValue: name))
                #expect(ResolverVerificationHex.string(raw) == key.string("publicKeyHex"), Comment(rawValue: name))
            }
        }
    }
    
    @Test
    func everyInstantTruncatesToTheListedEpochMilliseconds() throws {
        for vector in vectors.section("instants") {
            let iso = vector.string("iso")
            let instant = try #require(ResolverInstant(iso: iso), Comment(rawValue: iso))
            #expect(instant.epochMilliseconds == Int64(vector.string("epochMs")), Comment(rawValue: iso))
        }
    }
    
    @Test
    func everyRosterVectorReproducesItsBytesAndVerdict() throws {
        for vector in vectors.section("rosters") {
            let name = vector.string("name")
            let roster = try vector.decode(SignedRosterDocument.self, at: "roster")
            let form = try #require(CanonicalRoster.form(of: roster), Comment(rawValue: name))
            #expect(form.rawValue == vector.string("form"), Comment(rawValue: name))
            let canonical = try #require(CanonicalRoster.bytes(of: roster, form: form), Comment(rawValue: name))
            #expect(String(bytes: canonical, encoding: .utf8) == vector.string("canonicalUtf8"), Comment(rawValue: name))
            #expect(ResolverVerificationHex.string(canonical) == vector.string("canonicalHex"), Comment(rawValue: name))
            #expect(ResolverVerificationCrypto.sha256Hex(canonical) == vector.string("sha256Hex"), Comment(rawValue: name))
            
            let count = Self.authorityCount(roster, canonical: canonical, vector: vector)
            #expect(count.valid == vector.int("validSignatures"), Comment(rawValue: name))
            #expect((count.valid >= vector.int("threshold")) == vector.bool("verified"), Comment(rawValue: name))
        }
    }
    
    @Test
    func everyRosterRejectionIsRefusedWithItsOutcome() throws {
        for vector in vectors.section("rosterRejections") {
            let name = vector.string("name")
            let roster = try vector.decode(SignedRosterDocument.self, at: "roster")
            #expect(!vector.bool("verified"), Comment(rawValue: name))
            guard let offeredForm = RosterForm(rawValue: vector.string("form")) else {
                #expect(CanonicalRoster.form(of: roster) == nil, Comment(rawValue: name))
                #expect(ResolverVerificationReport.RosterSignature.unverifiable(.mixedRosterForm).summary.code == vector.string("expectedOutcome"), Comment(rawValue: name))
                continue
            }
            let canonical = try #require(CanonicalRoster.bytes(of: roster, form: offeredForm), Comment(rawValue: name))
            #expect(ResolverVerificationHex.string(canonical) == vector.string("canonicalHex"), Comment(rawValue: name))
            let count = Self.authorityCount(roster, canonical: canonical, vector: vector)
            #expect(count.valid == vector.int("validSignatures"), Comment(rawValue: name))
            let outcome: ResolverVerificationReport.RosterSignature = count.failureReason(threshold: vector.int("threshold")).map { .invalid($0) } ?? .valid
            #expect(outcome.summary.code == vector.string("expectedOutcome"), Comment(rawValue: name))
            // The app follows the served JSON, so a roster that fails only under the other form verifies.
            let servedForm = try #require(CanonicalRoster.form(of: roster), Comment(rawValue: name))
            if servedForm != offeredForm {
                let servedCanonical = try #require(CanonicalRoster.bytes(of: roster, form: servedForm), Comment(rawValue: name))
                #expect(Self.authorityCount(roster, canonical: servedCanonical, vector: vector).failureReason(threshold: vector.int("threshold")) == nil, Comment(rawValue: name))
            }
        }
    }
    
    private static func authorityCount(_ roster: SignedRosterDocument, canonical: [UInt8], vector: JSONObject) -> ResolverSignatureCounter.Count {
        ResolverSignatureCounter.count(signatures: roster.authoritySignatures.map { ($0.authorityKeyId, $0.signatureB64) },
                                       over: canonical, keys: ResolverSignatureCounter.keys(vector.trustedKeys))
    }
    
    @Test
    func theLogVectorsReproduceLeavesRootsAndProofs() throws {
        let log = vectors.object("log")
        var leafHashes = [String]()
        for event in log.section("events") {
            let name = "event \(event.int("index"))"
            let recordedAt = try #require(ResolverInstant(iso: event.string("recordedAt")), Comment(rawValue: name))
            let leafData = MerkleTree.leafData(index: event.int("index"), type: event.string("type"),
                                               homeserverId: event.stringIfPresent("homeserverId"),
                                               payloadHash: event.string("payloadHash"),
                                               recordedAtEpochMilliseconds: recordedAt.epochMilliseconds)
            #expect(leafData == event.string("leafDataUtf8"), Comment(rawValue: name))
            let leafHash = MerkleTree.leafHash(Array(leafData.utf8))
            #expect(leafHash == event.string("leafHashHex"), Comment(rawValue: name))
            leafHashes.append(leafHash)
        }
        for root in log.section("roots") {
            let size = root.int("size")
            #expect(MerkleTree.root(leafHashes: Array(leafHashes.prefix(size))) == root.string("rootHex"), "root at size \(size)")
        }
        for proof in log.section("consistencyProofs") {
            let name = "consistency \(proof.int("first")),\(proof.int("second"))"
            #expect(proof.bool("valid"), Comment(rawValue: name))
            #expect(MerkleTree.verifyConsistency(first: proof.int("first"), second: proof.int("second"),
                                                 oldRoot: proof.string("oldRootHex"), newRoot: proof.string("newRootHex"),
                                                 proof: proof.stringArray("proof")), Comment(rawValue: name))
        }
        for proof in log.section("invalidConsistencyProofs") {
            let name = proof.string("name")
            #expect(!proof.bool("valid"), Comment(rawValue: name))
            #expect(!MerkleTree.verifyConsistency(first: proof.int("first"), second: proof.int("second"),
                                                  oldRoot: proof.string("oldRootHex"), newRoot: proof.string("newRootHex"),
                                                  proof: proof.stringArray("proof")), Comment(rawValue: name))
        }
    }
    
    @Test
    func everyPolicyVectorReproducesItsBytesAndVerdict() throws {
        for vector in vectors.section("policies") + vectors.section("policyRejections") {
            let name = vector.string("name")
            let bundle = try vector.decode(RoutingPolicyBundle.self, at: "bundle")
            let canonical = try #require(CanonicalRoutingPolicy.bytes(of: bundle), Comment(rawValue: name))
            #expect(String(bytes: canonical, encoding: .utf8) == vector.string("canonicalUtf8"), Comment(rawValue: name))
            #expect(ResolverVerificationHex.string(canonical) == vector.string("canonicalHex"), Comment(rawValue: name))
            #expect(ResolverVerificationCrypto.sha256Hex(canonical) == vector.string("sha256Hex"), Comment(rawValue: name))
            for zone in vector.section("delegatedRules") {
                let delegated = CanonicalRoutingPolicy.delegatedRulesBytes(policyId: bundle.policyId, version: bundle.version,
                                                                           zoneId: zone.string("zoneId"), rules: bundle.rules)
                #expect(ResolverVerificationHex.string(delegated) == zone.string("canonicalHex"), "\(name) \(zone.string("zoneId"))")
            }
            let count = RoutingPolicyVerifier.validSignatureCount(of: bundle, canonical: canonical,
                                                                  keys: ResolverSignatureCounter.keys(vector.trustedKeys))
            #expect((count.valid >= vector.int("threshold")) == vector.bool("verified"), Comment(rawValue: name))
            #expect(RoutingPolicyVerifier.delegateVerifiedZones(of: bundle) == Set(vector.stringArray("delegateVerifiedZones")), Comment(rawValue: name))
        }
    }
    
    @Test
    func everyPolicyRejectionIsRefusedWithItsOutcome() throws {
        for vector in vectors.section("policyRejections") {
            let name = vector.string("name")
            let bundle = try vector.decode(RoutingPolicyBundle.self, at: "bundle")
            let canonical = try #require(CanonicalRoutingPolicy.bytes(of: bundle), Comment(rawValue: name))
            let keys = ResolverSignatureCounter.keys(vector.trustedKeys)
            let failure = keys.isEmpty ? nil : RoutingPolicyVerifier.validSignatureCount(of: bundle, canonical: canonical, keys: keys)
                .failureReason(threshold: vector.int("threshold"))
            let outcome: ResolverVerificationReport.Policy = keys.isEmpty ? .unverifiable(.noPolicyKeys) : failure.map { .invalid($0) } ?? .valid
            #expect(!vector.bool("verified"), Comment(rawValue: name))
            #expect(outcome.summary.code == vector.string("expectedOutcome"), Comment(rawValue: name))
        }
    }
    
    @Test
    func everyPolicyValidityEdgeIsInEffectAsListed() throws {
        let policies = vectors.byRef("policies")
        for vector in vectors.section("policyValidity") {
            let name = vector.string("name")
            let bundle = try #require(policies[vector.string("policyRef")], Comment(rawValue: name)).decode(RoutingPolicyBundle.self, at: "bundle")
            let evaluatedAt = try #require(ResolverInstant(iso: vector.string("evaluatedAt")), Comment(rawValue: name))
            #expect(bundle.isInEffect(atEpochMilliseconds: evaluatedAt.epochMilliseconds) == vector.bool("inEffect"), Comment(rawValue: name))
        }
    }
    
    @Test
    func everyWindowIsInEffectAsListed() throws {
        for vector in vectors.section("windows") {
            let name = vector.string("name")
            let window = Window(notBefore: vector.stringIfPresent("notBefore"), expiresAt: vector.stringIfPresent("expiresAt"))
            let evaluatedAt = try #require(ResolverInstant(iso: vector.string("evaluatedAt")), Comment(rawValue: name))
            #expect(window.isInEffect(atEpochMilliseconds: evaluatedAt.epochMilliseconds) == vector.bool("inEffect"), Comment(rawValue: name))
        }
    }
    
    private struct Window: ResolverValidityWindow {
        let notBefore: String?
        let expiresAt: String?
    }
    
    @Test
    func everyPolicyLogCaseGivesItsOutcome() throws {
        let events = try vectors.object("log").decode([TransparencyLogEvent].self, at: "events")
        for vector in vectors.section("policyLog") {
            let name = vector.string("name")
            let served = vector.objectIfPresent("servedPolicy").map { policy in
                ServedPolicy(policyId: policy.stringIfPresent("policyId"), version: Int64(policy.int("version")), contentHash: policy.string("sha256Hex"))
            }
            let checkpoint = vector.object("checkpoint")
            let outcome = ResolverVerifier.logOutcome(for: served, checkpoint: RosterLogCheckpoint(merkleRoot: checkpoint.string("rootHex"), size: checkpoint.int("size")),
                                                      events: events)
            #expect(outcome.summary.code == vector.string("expected"), Comment(rawValue: name))
        }
    }
    
    @Test
    func everyPlacementVectorReproducesTheReferenceDecision() throws {
        let rosters = vectors.byRef("rosters")
        let policies = vectors.byRef("policies")
        for vector in vectors.section("placements") {
            let name = vector.string("name")
            let roster = try #require(rosters[vector.string("rosterRef")], Comment(rawValue: name)).decode(SignedRosterDocument.self, at: "roster")
            var policy: VerifiedRoutingPolicy?
            if let policyRef = vector.stringIfPresent("policyRef") {
                let policyVector = try #require(policies[policyRef], Comment(rawValue: name))
                let bundle = try policyVector.decode(RoutingPolicyBundle.self, at: "bundle")
                let canonical = try #require(CanonicalRoutingPolicy.bytes(of: bundle), Comment(rawValue: name))
                let count = RoutingPolicyVerifier.validSignatureCount(of: bundle, canonical: canonical,
                                                                      keys: ResolverSignatureCounter.keys(policyVector.trustedKeys))
                #expect(count.valid >= policyVector.int("threshold"), Comment(rawValue: name))
                policy = VerifiedRoutingPolicy(bundle: bundle, delegateVerifiedZones: RoutingPolicyVerifier.delegateVerifiedZones(of: bundle))
            }
            // Unproven affiliations and attributes are dropped, as on the server.
            let contextJSON = vector.object("context")
            let context = PlacementContext(phone: contextJSON.stringIfPresent("phone"),
                                           country: contextJSON.stringIfPresent("country"),
                                           mccmnc: contextJSON.stringIfPresent("mccmnc"),
                                           carrier: contextJSON.stringIfPresent("carrier"),
                                           regionHint: contextJSON.stringIfPresent("regionHint"))
            let evaluatedAt = try #require(ResolverInstant(iso: vector.string("evaluatedAt")), Comment(rawValue: name)).epochMilliseconds
            let decision = PlacementReproducer.decide(context: context, roster: roster, policy: policy, nowEpochMilliseconds: evaluatedAt)
            let reference = decision.map(Self.reference(of:))
            #expect((decision == nil) == (vector.dictionary["expectedHomeserverId"] is NSNull), Comment(rawValue: name))
            #expect(decision?.homeserver.id == vector.stringIfPresent("expectedHomeserverId"), Comment(rawValue: name))
            #expect(reference?.rule == vector.stringIfPresent("expectedRule"), Comment(rawValue: name))
            #expect(reference?.ruleId == vector.stringIfPresent("expectedRuleId"), Comment(rawValue: name))
            let unsignedRuleAbove = policy.map {
                PlacementReproducer.unsignedRuleRanksAbove(decision, context: context, policy: $0, nowEpochMilliseconds: evaluatedAt)
            } ?? false
            #expect(unsignedRuleAbove == vector.bool("unsignedRuleAbove"), Comment(rawValue: name))
            if let fallback = vector.objectIfPresent("fallback") {
                #expect(context.canonicalRoutingKey == fallback.string("routingKeyUtf8"), Comment(rawValue: name))
                let candidates = PlacementReproducer.fallbackCandidates(in: roster)
                #expect(candidates.map { $0.id ?? "null" } == fallback.array("candidates").map { JSONObject($0).string("id") }, Comment(rawValue: name))
                #expect(candidates.map { Int(max(0, $0.weight)) } == fallback.array("candidates").map { JSONObject($0).int("weight") }, Comment(rawValue: name))
                #expect(PlacementReproducer.totalWeight(of: candidates) == Int64(fallback.int("totalWeight")), Comment(rawValue: name))
                #expect(PlacementReproducer.stableHash(context: context, rosterVersion: roster.version, candidates: candidates) == Int32(fallback.int("stableHash")), Comment(rawValue: name))
                #expect(roster.version == Int64(fallback.int("rosterVersion")), Comment(rawValue: name))
            }
        }
    }
    
    private static func reference(of decision: PlacementDecision) -> (rule: String, ruleId: String) {
        switch decision.rule {
        case .policy(let rule): ("PolicyRoutingRule", rule.id ?? "")
        case .rosterClaim(let priority): ("ClaimRule", "roster-claim:\(decision.homeserver.id ?? "null"):\(priority)")
        case .weightedFallback: ("WeightedFallbackRule", "weighted-fallback")
        }
    }
    
    @Test
    func everyResolveAnswerVectorLocatesAsExpected() throws {
        let rosters = vectors.byRef("rosters")
        for vector in vectors.section("resolveAnswers") {
            let name = vector.string("name")
            let roster = try #require(rosters[vector.string("rosterRef")], Comment(rawValue: name)).decode(SignedRosterDocument.self, at: "roster")
            let answer = vector.object("answer")
            let located = ResolverVerifier.locate(ResolvedHomeserver(serverName: answer.string("serverName"), baseURL: answer.string("baseUrl"),
                                                                     masIssuer: answer.stringIfPresent("masIssuer"), region: nil),
                                                  in: roster)
            #expect(located.match.summary.code == vector.string("expected"), Comment(rawValue: name))
            #expect(located.entry?.homeserver.id == vector.stringIfPresent("expectedEntryId"), Comment(rawValue: name))
        }
    }
    
    @Test
    func everyEd25519CaseHasItsExpectedVerdict() throws {
        for vector in vectors.section("ed25519Cases") {
            let name = vector.string("name")
            let message = try #require(ResolverVerificationHex.bytes(vector.string("messageHex")), Comment(rawValue: name))
            let verified = ResolverVerificationCrypto.publicKey(spkiBase64: vector.string("publicKeySpkiB64")).map {
                ResolverVerificationCrypto.verify(signatureBase64: vector.string("signatureB64"), over: message, key: $0)
            } ?? false
            #expect(verified == vector.bool("verifies"), Comment(rawValue: name))
        }
    }
    
    @Test
    func everyPrimitiveEncodesToItsBytes() throws {
        for vector in lpVectors.section("primitives") {
            let name = vector.string("name")
            var encoder = GuaLPEncoder()
            switch vector.string("type") {
            case "string": encoder.string(vector.string("value"))
            case "int64": try encoder.int64(#require(Int64(vector.string("value")), Comment(rawValue: name)))
            case "bool": encoder.bool(vector.bool("value"))
            case "optionalString": encoder.optionalString(vector.stringIfPresent("value"))
            case "stringSet": try encoder.stringSet(vector.stringArray("value"))
            case "stringList": encoder.stringList(vector.stringArray("value"))
            case "enum": encoder.enumName(vector.string("value"))
            default: Issue.record("unknown primitive type in \(name)")
            }
            #expect(ResolverVerificationHex.string(encoder.bytes) == vector.string("hex"), Comment(rawValue: name))
        }
    }
    
    @Test
    func everyMemberEntryReproducesItsBytesAndVerifies() throws {
        for vector in lpVectors.section("memberEntries") {
            let name = vector.string("name")
            let homeserver = try vector.memberHomeserver()
            let member = try vector.decode(RosterMemberAttestation.self, at: "member")
            let notBeforeISO = try #require(member.notBefore, Comment(rawValue: name))
            let notAfterISO = try #require(member.notAfter, Comment(rawValue: name))
            let notBefore = try #require(ResolverInstant(iso: notBeforeISO), Comment(rawValue: name))
            let notAfter = try #require(ResolverInstant(iso: notAfterISO), Comment(rawValue: name))
            #expect(notBefore.epochMilliseconds == Int64(vector.int("notBeforeEpochMs")), Comment(rawValue: name))
            #expect(notAfter.epochMilliseconds == Int64(vector.int("notAfterEpochMs")), Comment(rawValue: name))
            let canonical = try CanonicalMemberEntry.bytes(homeserver: homeserver, member: member,
                                                           notBefore: notBefore.epochMilliseconds, notAfter: notAfter.epochMilliseconds)
            #expect(ResolverVerificationHex.string(canonical) == vector.string("canonicalHex"), Comment(rawValue: name))
            #expect(ResolverVerificationCrypto.sha256Hex(canonical) == vector.string("sha256Hex"), Comment(rawValue: name))
            #expect(MemberEntryVerifier.verify(homeserver: homeserver, member: member, atEpochMilliseconds: now) == .valid, Comment(rawValue: name))
        }
    }
    
    @Test
    func everyMemberEntryRejectionIsRefused() throws {
        // A rotation can only be refused against an entry accepted earlier, and the app keeps none.
        for vector in lpVectors.section("rejections") where vector.objectIfPresent("previous") == nil {
            let name = vector.string("name")
            let homeserver = try vector.memberHomeserver()
            guard let member = try? vector.decode(RosterMemberAttestation.self, at: "member") else {
                #expect(name.contains("unknown field"), "\(name): the member block should decode")
                continue
            }
            let outcome = MemberEntryVerifier.verify(homeserver: homeserver, member: member, atEpochMilliseconds: now)
            guard case .invalid = outcome else {
                Issue.record("\(name): expected the entry to be refused, got \(outcome)")
                continue
            }
        }
    }
}

private extension GuaLPEncoder {
    mutating func bool(_ value: Bool) {
        bytes.append(value ? 1 : 0)
    }
    
    mutating func stringList(_ values: [String]) {
        bytes.append(contentsOf: withUnsafeBytes(of: UInt32(values.count).bigEndian, Array.init))
        for value in values {
            string(value)
        }
    }
}

private struct JSONObject {
    let dictionary: [String: Any]
    
    init(_ any: Any) {
        dictionary = any as? [String: Any] ?? [:]
    }
    
    static func load(_ resource: String) throws -> JSONObject {
        let url = try #require(Bundle(for: ResolverVerificationVectorsTests.self).url(forResource: resource, withExtension: nil), "\(resource) is missing from the test bundle.")
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
    
    func int(_ key: String) -> Int {
        (dictionary[key] as? NSNumber)?.intValue ?? Int(string(key)) ?? 0
    }
    
    func bool(_ key: String) -> Bool {
        dictionary[key] as? Bool ?? false
    }
    
    /// An empty section fails, so a renamed or dropped key cannot pass silently.
    func section(_ key: String, sourceLocation: SourceLocation = #_sourceLocation) -> [JSONObject] {
        let items = array(key).map(JSONObject.init)
        #expect(!items.isEmpty, "the \(key) section is empty", sourceLocation: sourceLocation)
        return items
    }
    
    /// Member vectors carry only the fields the member signs, so the authority attributes the decoder needs are filled in.
    func memberHomeserver() throws -> RosterHomeserver {
        var homeserver = object("homeserver").dictionary
        homeserver["weight"] = homeserver["weight"] ?? 0
        homeserver["acceptsNew"] = homeserver["acceptsNew"] ?? false
        return try JSONDecoder().decode(RosterHomeserver.self, from: JSONSerialization.data(withJSONObject: homeserver))
    }
    
    func byRef(_ key: String) -> [String: JSONObject] {
        Dictionary(section(key).compactMap { vector in vector.stringIfPresent("ref").map { ($0, vector) } }) { first, _ in first }
    }
    
    var trustedKeys: [ResolverTrustedKey] {
        array("trustedKeys").map(JSONObject.init).map { ResolverTrustedKey(id: $0.string("id"), publicKey: $0.string("publicKeySpkiB64")) }
    }
    
    func decode<T: Decodable>(_ type: T.Type, at key: String) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: dictionary[key] as Any)
        return try JSONDecoder().decode(type, from: data)
    }
}
