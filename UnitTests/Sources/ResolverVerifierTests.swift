//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Combine
import CryptoKit
@testable import ElementX
import Foundation
import Testing
import UIKit

/// Modified rosters are re-signed with the RFC 8032 test keys so their signatures verify.
final class ResolverVerifierTests {
    private static let phone = "+5511987654321"
    
    private var vectors: [String: Any]!
    private var checkpoints: InMemoryCheckpointStore!
    /// Unique per test: runs are serialized per base URL across the process.
    private var baseURL: URL!
    /// A moment inside every validity window the vectors sign.
    private var now: Int64 = 0
    
    init() throws {
        VerifierStub.reset()
        let url = try #require(Bundle(for: Self.self).url(forResource: "gua-client-verification-v1-vectors.json", withExtension: nil))
        vectors = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        checkpoints = InMemoryCheckpointStore()
        baseURL = URL(string: "https://resolver-\(UUID().uuidString.lowercased()).example")
        now = try instant("2026-10-27T00:00:00Z")
    }
    
    deinit {
        VerifierStub.reset()
    }
    
    @Test
    func developmentTrustRootsReadTheTokenFormat() throws {
        let first = try spki("rfc8032-test1")
        let second = try spki("rfc8032-test2")
        let roots = ResolverTrustRoots(developmentSecret: "authority:a:\(first)\nauthority:b:\(second)  authority-threshold:2 policy:g:\(second)")
        
        #expect(roots.authorityKeys == [ResolverTrustedKey(id: "a", publicKey: first), ResolverTrustedKey(id: "b", publicKey: second)])
        #expect(roots.authorityThreshold == 2)
        #expect(roots.policyKeys == [ResolverTrustedKey(id: "g", publicKey: second)])
        #expect(roots.policyThreshold == 1)
    }
    
    @Test
    func developmentTrustRootsCopyNoKeyToTheOtherList() throws {
        let roots = try ResolverTrustRoots(developmentSecret: "authority:a:\(spki("rfc8032-test1"))")
        
        #expect(roots.authorityKeys.map(\.id) == ["a"])
        #expect(roots.policyKeys.isEmpty)
    }
    
    @Test
    func malformedDevelopmentTrustRootsAreRefusedWhole() throws {
        let key = try spki("rfc8032-test1")
        for value in ["authority:a", "authority:a:not-base64", "authority::\(key)", "trusted:a:\(key)", "gua-authority-dev:\(key)",
                      "authority-threshold:0", "authority:a:\(key) policy-threshold:two"] {
            #expect(ResolverTrustRoots(developmentSecret: value) == .empty, Comment(rawValue: value))
        }
        #expect(ResolverTrustRoots(developmentSecret: "  ") == .empty)
        #expect(ResolverTrustRoots(developmentSecret: nil) == .empty)
    }
    
    @Test
    func productionTrustRootsListNoPolicyKeys() {
        #expect(ResolverTrustRoots.production.authorityKeys.map(\.id) == ["gua-authority-prod"])
        #expect(ResolverTrustRoots.production.policyKeys.isEmpty)
    }
    
    @Test
    func noTrustRootsIsUnverifiableAndFetchesNothing() async throws {
        let report = try await verified(makeVerifier(trustRoots: .empty), answer())
        
        #expect(report == stopped(rosterSignature: .unverifiable(.noTrustRoots), others: .noTrustRoots, durationMs: report.durationMs))
        #expect(report.overall == .unverifiable(.rosterSignature))
        #expect(VerifierStub.requestedPaths.isEmpty)
    }
    
    @Test
    func malformedConfiguredKeysAreNoTrustRoots() async throws {
        let malformed = ResolverTrustRoots(authorityKeys: [ResolverTrustedKey(id: "authority-a", publicKey: "not-a-key")], authorityThreshold: 1,
                                           policyKeys: [], policyThreshold: 1)
        let report = try await verified(makeVerifier(trustRoots: malformed), answer())
        
        #expect(report == stopped(rosterSignature: .unverifiable(.noTrustRoots), others: .noTrustRoots, durationMs: report.durationMs))
        #expect(VerifierStub.requestedPaths.isEmpty)
    }
    
    @Test
    func killSwitchOffVerifiesNothing() async throws {
        let verifier = try makeVerifier(trustRoots: trustRoots(ofRoster: "r1"), isEnabled: false)
        
        let report = await verifier.verify(resolution: answer(), phoneNumber: Self.phone)
        
        #expect(report == nil)
        #expect(verifier.lastReport == nil)
        #expect(VerifierStub.requestedPaths.isEmpty)
    }
    
    @Test
    func rosterUnavailableIsUnverifiable() async throws {
        VerifierStub.respond(path: "/roster", status: 503, body: "{}")
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r1")), answer())
        
        #expect(report == stopped(rosterSignature: .unverifiable(.rosterUnavailable), durationMs: report.durationMs))
        #expect(VerifierStub.requestedPaths == ["/roster"])
    }
    
    @Test
    func transportFailureIsUnverifiable() async throws {
        VerifierStub.failsTransport = true
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r1")), answer())
        
        #expect(report.rosterSignature == .unverifiable(.rosterUnavailable))
        #expect(report.overall == .unverifiable(.rosterSignature))
    }
    
    @Test
    func mixedRosterFormIsRefusedBeforeAnySignatureCheck() async throws {
        let mixed = try #require(section("rosterRejections").first { $0["clientOnly"] as? Bool == true })
        try VerifierStub.respond(path: "/roster", body: json(mixed["roster"]))
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r2")), answer())
        
        #expect(report == stopped(rosterForm: "mixed", rosterSignature: .unverifiable(.mixedRosterForm), durationMs: report.durationMs))
        #expect(VerifierStub.requestedPaths == ["/roster"])
    }
    
    @Test
    func tamperedRosterIsInvalidAndStopsTheDependentChecks() async throws {
        let tampered = try vector("rosterRejections", named: "baseUrl changed after signing")
        try VerifierStub.respond(path: "/roster", body: json(tampered["roster"]))
        let report = try await verified(makeVerifier(trustRoots: trustRoots(of: tampered)), answer())
        
        #expect(report == stopped(rosterForm: "v1", rosterSignature: .invalid(.badSignature), durationMs: report.durationMs))
        #expect(report.overall == .failed(.rosterSignature))
        #expect(try checkpoints.checkpoint(for: baseURL) == nil)
    }
    
    @Test
    func rosterVersionIsReportedOnlyOnceTheSignatureIsValid() async throws {
        let tampered = try vector("rosterRejections", named: "baseUrl changed after signing")
        try VerifierStub.respond(path: "/roster", body: json(tampered["roster"]))
        let report = try await verified(makeVerifier(trustRoots: trustRoots(of: tampered)), answer())
        
        #expect(report.rosterVersion == nil)
        #expect(report.logDescription.contains("rosterVersion=none rosterForm=v1 rosterSignature=invalid(bad_signature)"))
    }
    
    @Test
    func rosterWithAnUnknownStatusFailsItsSignature() async throws {
        let roster = try editing(rosterJSON("r1"), entry: 0) { $0["status"] = "RETIRED" }
        try VerifierStub.respond(path: "/roster", body: json(roster))
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r1")), answer())
        
        #expect(report.rosterSignature == .invalid(.badSignature))
    }
    
    @Test
    func deeplyNestedIgnoredFieldIsAParseError() async throws {
        try VerifierStub.respond(path: "/roster", status: 200, body: rosterJSONText("r1", ignoredFieldNesting: 100_000))
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r1")), answer())
        
        #expect(report.rosterSignature == .unverifiable(.parseError))
    }
    
    @Test
    func rosterNestedSixtyFourLevelsDeepVerifies() async throws {
        try VerifierStub.respond(path: "/roster", status: 200, body: rosterJSONText("r1", ignoredFieldNesting: 63))
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r1")), answer())
        
        #expect(report.rosterSignature == .valid)
    }
    
    @Test
    func rosterNestedSixtyFiveLevelsDeepIsAParseError() async throws {
        // Past the verifier's cap of 64 but far inside JSONDecoder's own limit, so only the cap can refuse it.
        try VerifierStub.respond(path: "/roster", status: 200, body: rosterJSONText("r1", ignoredFieldNesting: 64))
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r1")), answer())
        
        #expect(report.rosterSignature == .unverifiable(.parseError))
    }
    
    @Test
    func deeplyNestedMemberBlockIsAParseError() async throws {
        let nested = String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000)
        let roster = try editing(rosterJSON("r1"), entry: 0) { $0["member"] = "NESTED" }
        let document = try #require(String(bytes: json(roster), encoding: .utf8)).replacingOccurrences(of: #""NESTED""#, with: nested)
        VerifierStub.respond(path: "/roster", status: 200, body: document)
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r1")), answer())
        
        #expect(report.rosterSignature == .unverifiable(.parseError))
    }
    
    @Test
    func bodyOverTheSizeCapIsAParseError() async throws {
        // A well formed and validly signed roster, so only the cap can refuse it.
        var roster = try rosterJSON("r1")
        roster["pad"] = String(repeating: "x", count: 3 * 1024 * 1024)
        try VerifierStub.respond(path: "/roster", body: json(roster))
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r1")), answer())
        
        #expect(report.rosterSignature == .unverifiable(.parseError))
    }
    
    @Test
    func nullHomeserverNamesAreSignedAsNull() throws {
        let roster = try editing(rosterJSON("r1"), entry: 0) { entry in
            var homeserver = entry["homeserver"] as? [String: Any] ?? [:]
            homeserver["serverName"] = NSNull()
            homeserver["baseUrl"] = NSNull()
            entry["homeserver"] = homeserver
        }
        let document = try JSONDecoder().decode(SignedRosterDocument.self, from: json(roster))
        let canonical = try #require(CanonicalRoster.bytes(of: document, form: .v1).flatMap { String(bytes: $0, encoding: .utf8) })
        
        #expect(canonical.contains("\nhs-br\u{1F}null\u{1F}null\u{1F}https://account.br.gua.test\u{1F}"))
    }
    
    @Test
    func weightOutsideInt32IsAParseError() async throws {
        let roster = try editing(rosterJSON("r1"), entry: 0) { entry in
            var homeserver = entry["homeserver"] as? [String: Any] ?? [:]
            homeserver["weight"] = 3_000_000_000
            entry["homeserver"] = homeserver
        }
        try VerifierStub.respond(path: "/roster", body: json(roster))
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r1")), answer())
        
        #expect(report.rosterSignature == .unverifiable(.parseError))
    }
    
    @Test
    func checkpointSizeOutsideThirtyOneBitsIsAParseError() async throws {
        var roster = try rosterJSON("r1")
        roster["logCheckpoint"] = ["merkleRoot": logRoot(size: 3), "size": 2_147_483_648]
        try VerifierStub.respond(path: "/roster", body: json(roster))
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r1")), answer())
        
        #expect(report.rosterSignature == .unverifiable(.parseError))
    }
    
    @Test
    func nullEntriesListIsAParseError() async throws {
        var roster = try rosterJSON("r1")
        roster["entries"] = NSNull()
        try VerifierStub.respond(path: "/roster", body: json(roster))
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r1")), answer())
        
        #expect(report.rosterSignature == .unverifiable(.parseError))
    }
    
    @Test
    func rosterFieldsThatAreNeverNullRefuseNull() throws {
        for field in ["version", "issuedAt", "logCheckpoint", "entries", "authoritySignatures"] {
            var roster = try rosterJSON("r1")
            roster[field] = NSNull()
            #expect(throws: (any Error).self, Comment(rawValue: field)) { try JSONDecoder().decode(SignedRosterDocument.self, from: json(roster)) }
        }
        for field in ["homeserver", "status"] {
            let roster = try editing(rosterJSON("r1"), entry: 0) { $0[field] = NSNull() }
            #expect(throws: (any Error).self, Comment(rawValue: field)) { try JSONDecoder().decode(SignedRosterDocument.self, from: json(roster)) }
        }
        for field in ["weight", "acceptsNew"] {
            let roster = try editing(rosterJSON("r1"), entry: 0) { entry in
                var homeserver = entry["homeserver"] as? [String: Any] ?? [:]
                homeserver[field] = NSNull()
                entry["homeserver"] = homeserver
            }
            #expect(throws: (any Error).self, Comment(rawValue: field)) { try JSONDecoder().decode(SignedRosterDocument.self, from: json(roster)) }
        }
    }
    
    @Test
    func numberOrBooleanSentAsAStringIsAParseError() throws {
        var version = try rosterJSON("r1")
        version["version"] = "3"
        var size = try rosterJSON("r1")
        size["logCheckpoint"] = ["merkleRoot": logRoot(size: 3), "size": "3"]
        let weight = try editing(rosterJSON("r1"), entry: 0) { entry in
            var homeserver = entry["homeserver"] as? [String: Any] ?? [:]
            homeserver["weight"] = "5"
            entry["homeserver"] = homeserver
        }
        let acceptsNew = try editing(rosterJSON("r1"), entry: 0) { entry in
            var homeserver = entry["homeserver"] as? [String: Any] ?? [:]
            homeserver["acceptsNew"] = "true"
            entry["homeserver"] = homeserver
        }
        for (name, roster) in [("version", version), ("size", size), ("weight", weight), ("acceptsNew", acceptsNew)] {
            #expect(throws: (any Error).self, Comment(rawValue: name)) { try JSONDecoder().decode(SignedRosterDocument.self, from: json(roster)) }
        }
    }
    
    @Test
    func timestampsNeedFourYearDigitsWithoutASign() {
        #expect(ResolverInstant(iso: "2026-10-01T12:00:00Z") != nil)
        for text in ["+2026-10-01T12:00:00Z", "-2026-10-01T12:00:00Z", "02026-10-01T12:00:00Z", "226-10-01T12:00:00Z",
                     "2026-10-01t12:00:00Z", "2026-10-01T12:00:00z", "2026-10-01T12:00:00+00:00"] {
            #expect(ResolverInstant(iso: text) == nil, Comment(rawValue: text))
        }
    }
    
    @Test
    func rosterServedWithAnother2xxIsRead() async throws {
        try VerifierStub.respond(path: "/roster", status: 203, body: json(rosterJSON("r1")))
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r1")), answer())
        
        #expect(report.rosterSignature == .valid)
    }
    
    @Test
    func claimPriorityOutsideInt32IsAParseError() async throws {
        let roster = try editing(rosterJSON("r1"), entry: 0) { $0["claims"] = [["country": "BR", "priority": 2_147_483_648]] }
        try VerifierStub.respond(path: "/roster", body: json(roster))
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r1")), answer())
        
        #expect(report.rosterSignature == .unverifiable(.parseError))
    }
    
    @Test
    func redirectedHomeserverIsAFieldMismatch() async throws {
        try serve(roster: "r2", policy: "br-policy v3")
        let redirected = HomeserverResolution(exists: true,
                                              homeserver: ResolvedHomeserver(serverName: "br.gua.test", baseURL: "https://matrix.evil.test",
                                                                             masIssuer: "https://account.br.gua.test", region: nil))
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r2", policy: "br-policy v3")), redirected)
        
        #expect(report.homeserverMatch == .fieldMismatch)
        #expect(report.memberEntry == .unverifiable(.noMatchingEntry))
        #expect(report.overall == .failed(.homeserverMatch))
    }
    
    @Test
    func memberEntryIsCheckedOnTheLocatedEntry() async throws {
        let entry = try #require((rosterJSON("r1")["entries"] as? [[String: Any]])?.first)
        var retired = entry
        retired["status"] = "SUSPENDED"
        var retiredHomeserver = try #require(entry["homeserver"] as? [String: Any])
        retiredHomeserver["id"] = "hs-br-retired"
        retired["homeserver"] = retiredHomeserver
        let retiredSignature = try memberSignature(of: retired)
        retired = withMemberSignature(retired, retiredSignature)
        let active = withMemberSignature(entry, retiredSignature)
        var roster = try rosterJSON("r1")
        roster["entries"] = [retired, active]
        try VerifierStub.respond(path: "/roster", body: json(signed(roster)))
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r1")), answer())
        
        #expect(report.homeserverMatch == .activeMatch)
        #expect(report.memberEntry == .invalid(.badSignature))
    }
    
    @Test
    func memberBlockWithANullFieldIsAParseError() async throws {
        let roster = try editing(rosterJSON("r1"), entry: 0) { entry in
            var member = entry["member"] as? [String: Any] ?? [:]
            member["keyId"] = NSNull()
            entry["member"] = member
        }
        try VerifierStub.respond(path: "/roster", body: json(roster))
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r1")), answer())
        
        #expect(report.rosterSignature == .valid)
        #expect(report.memberEntry == .invalid(.parseError))
    }
    
    @Test
    func firstCheckpointIsPinned() async throws {
        try serve(roster: "r1")
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r1")), answer())
        
        #expect(report.logConsistency == .firstSeen)
        #expect(try checkpoints.checkpoint(for: baseURL) == checkpoint(size: 3))
    }
    
    @Test
    func consistencyProofMovesThePinForward() async throws {
        try checkpoints.store(checkpoint(size: 3), for: baseURL)
        try serve(roster: "r2")
        try VerifierStub.respond(path: "/roster/log/consistency", body: proofDocument(first: 3, second: 7))
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r2")), answer())
        
        #expect(report.logConsistency == .consistent)
        #expect(try checkpoints.checkpoint(for: baseURL) == checkpoint(size: 7))
        #expect(VerifierStub.requestedQueries["/roster/log/consistency"] == "first=3&second=7")
    }
    
    @Test
    func brokenConsistencyProofIsInconsistentAndLeavesThePin() async throws {
        let pinned = RosterLogCheckpoint(merkleRoot: logRoot(size: 4), size: 3)
        try checkpoints.store(pinned, for: baseURL)
        try serve(roster: "r2")
        try VerifierStub.respond(path: "/roster/log/consistency", body: proofDocument(first: 3, second: 7))
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r2")), answer())
        
        #expect(report.logConsistency == .inconsistent)
        #expect(report.overall == .failed(.logConsistency))
        #expect(try checkpoints.checkpoint(for: baseURL) == pinned)
    }
    
    @Test
    func missingProofEndpointIsUnverifiableAndLeavesThePin() async throws {
        try checkpoints.store(checkpoint(size: 3), for: baseURL)
        try serve(roster: "r2")
        VerifierStub.respond(path: "/roster/log/consistency", status: 404, body: "{}")
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r2")), answer())
        
        #expect(report.logConsistency == .unverifiable(.logUnavailable))
        #expect(try checkpoints.checkpoint(for: baseURL) == checkpoint(size: 3))
    }
    
    @Test
    func proofHashThatIsNotLowercaseHexIsAParseError() async throws {
        try checkpoints.store(checkpoint(size: 3), for: baseURL)
        try serve(roster: "r2")
        let proof = (log["consistencyProofs"] as? [[String: Any]] ?? []).first { $0["first"] as? Int == 3 && $0["second"] as? Int == 7 }
        let uppercased = try #require(proof?["proof"] as? [String]).map { $0.uppercased() }
        try VerifierStub.respond(path: "/roster/log/consistency", body: json(["first": 3, "second": 7, "proof": uppercased]))
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r2")), answer())
        
        #expect(report.logConsistency == .unverifiable(.parseError))
        #expect(try checkpoints.checkpoint(for: baseURL) == checkpoint(size: 3))
    }
    
    @Test
    func smallerServedTreeIsARollback() async throws {
        try checkpoints.store(checkpoint(size: 7), for: baseURL)
        try serve(roster: "r1")
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r1")), answer())
        
        #expect(report.logConsistency == .rollback)
        #expect(report.overall == .failed(.logConsistency))
        #expect(try checkpoints.checkpoint(for: baseURL) == checkpoint(size: 7))
        #expect(!VerifierStub.requestedPaths.contains("/roster/log/consistency"))
    }
    
    @Test
    func unreadablePinStoreIsStorageUnavailable() async throws {
        try serve(roster: "r1")
        checkpoints.failsReads = true
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r1")), answer())
        
        #expect(report.logConsistency == .unverifiable(.storageUnavailable))
        #expect(checkpoints.writes == 0)
    }
    
    @Test
    func overlappingRunsKeepTheLargerPin() async throws {
        try checkpoints.store(checkpoint(size: 3), for: baseURL)
        try VerifierStub.enqueue(path: "/roster", body: json(roster("r1", checkpointSize: 5)))
        try VerifierStub.enqueue(path: "/roster", body: json(rosterJSON("r2")))
        try VerifierStub.respond(path: "/roster/log/consistency", query: "first=3&second=5", body: proofDocument(first: 3, second: 5), delay: 0.5)
        try VerifierStub.respond(path: "/roster/log/consistency", query: "first=5&second=7", body: proofDocument(first: 5, second: 7))
        try VerifierStub.respond(path: "/roster/log/consistency", query: "first=3&second=7", body: proofDocument(first: 3, second: 7))
        let trust = try trustRoots(ofRoster: "r1")
        let (requests, requestContinuation) = AsyncStream<String>.makeStream()
        VerifierStub.onRequest = { requestContinuation.yield($0) }
        let slowRosterFetched = deferFulfillment(requests, timeout: .seconds(5), message: "the run with the smaller checkpoint fetched its roster") { $0 == "/roster" }
        
        let slowVerifier = makeVerifier(trustRoots: trust)
        let fastVerifier = makeVerifier(trustRoots: trust)
        let resolution = answer()
        async let slowRun = slowVerifier.verify(resolution: resolution, phoneNumber: Self.phone)
        try await slowRosterFetched.fulfill()
        async let fastRun = fastVerifier.verify(resolution: resolution, phoneNumber: Self.phone)
        _ = await (slowRun, fastRun)
        #expect(try checkpoints.checkpoint(for: baseURL) == checkpoint(size: 7))
        
        try VerifierStub.respond(path: "/roster", body: json(roster("r1", checkpointSize: 6)))
        let later = try await verified(makeVerifier(trustRoots: trust), answer())
        #expect(later.logConsistency == .rollback)
    }
    
    @Test
    func noPolicyServedIsNotPresentAndThePlacementReproduces() async throws {
        try serve(roster: "r1")
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r1")), answer())
        
        #expect(report.rosterVersion == 3)
        #expect(report.rosterForm == "v1")
        #expect(report.rosterSignature == .valid)
        #expect(report.homeserverMatch == .activeMatch)
        #expect(report.memberEntry == .valid)
        #expect(report.logConsistency == .firstSeen)
        #expect(report.policy == .notPresent)
        #expect(report.placement == .match)
        #expect(report.overall == .verified)
    }
    
    @Test
    func policyPresentAndValidRoutesThePlacement() async throws {
        try serve(roster: "r2", policy: "br-policy v3")
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r2", policy: "br-policy v3")), answer())
        
        #expect(report.rosterVersion == 7)
        #expect(report.policy == .valid)
        #expect(report.placement == .match)
        #expect(report.overall == .verified)
        #expect(Set(VerifierStub.requestedPaths) == ["/roster", "/policy/routing", "/roster/log"])
    }
    
    @Test
    func policySignedByAnUntrustedKeyIsInvalid() async throws {
        try serve(roster: "r2")
        let untrusted = try vector("policyRejections", named: "signed by the roster authority key, which is not a policy key")
        try VerifierStub.respond(path: "/policy/routing", body: json(untrusted["bundle"]))
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r2", policy: "br-policy v3")), answer())
        
        #expect(report.policy == .invalid(.unknownKeyId))
        #expect(report.placement == .unverifiable(.policyUnverified))
        #expect(report.overall == .failed(.policy))
    }
    
    @Test
    func policyWithoutPolicyKeysIsUnverifiable() async throws {
        try serve(roster: "r2", policy: "br-policy v3")
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r2")), answer())
        
        #expect(report.policy == .unverifiable(.noPolicyKeys))
        #expect(report.overall == .unverifiable(.policy))
    }
    
    @Test
    func policyWithABadTimestampIsAParseErrorEvenWithoutPolicyKeys() async throws {
        try serve(roster: "r2")
        var bundle = try policyBundle("br-policy v3")
        bundle["notBefore"] = "2026-01-01"
        try VerifierStub.respond(path: "/policy/routing", body: json(bundle))
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r2")), answer())
        
        #expect(report.policy == .unverifiable(.parseError))
    }
    
    @Test
    func malformedPolicyKeysAreNoPolicyKeys() async throws {
        try serve(roster: "r2", policy: "br-policy v3")
        let authority = try trustRoots(ofRoster: "r2")
        let malformed = ResolverTrustRoots(authorityKeys: authority.authorityKeys, authorityThreshold: 1,
                                           policyKeys: [ResolverTrustedKey(id: "governance-a", publicKey: "not-a-key")], policyThreshold: 1)
        let report = try await verified(makeVerifier(trustRoots: malformed), answer())
        
        #expect(report.policy == .unverifiable(.noPolicyKeys))
    }
    
    @Test
    func policyPastItsExpiryIsOutsideItsWindow() async throws {
        try serve(roster: "r2", policy: "br-policy v3")
        now = try instant("2030-01-01T00:00:00Z")
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r2", policy: "br-policy v3")), answer())
        
        #expect(report.policy == .invalid(.outsideWindow))
        #expect(report.placement == .unverifiable(.policyUnverified))
        #expect(!VerifierStub.requestedPaths.contains("/roster/log"))
    }
    
    @Test
    func missingPolicyAfterAPublishedOneIsNotServed() async throws {
        try serve(roster: "r2")
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r2", policy: "br-policy v3")), answer())
        
        #expect(report.policy == .unverifiable(.policyNotServed))
        #expect(report.placement == .unverifiable(.policyUnverified))
    }
    
    @Test
    func missingPolicyWithAnUnreadableLogIsLogUnavailable() async throws {
        try serve(roster: "r1")
        VerifierStub.respond(path: "/roster/log", status: 503, body: "{}")
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r1")), answer())
        
        #expect(report.policy == .unverifiable(.logUnavailable))
        #expect(report.placement == .unverifiable(.policyUnverified))
    }
    
    @Test
    func policyWithALaterVersionLoggedIsSuperseded() async throws {
        try VerifierStub.respond(path: "/roster", body: json(roster("r2", checkpointSize: 8)))
        try VerifierStub.respond(path: "/policy/routing", body: json(policyBundle("br-policy v3")))
        try VerifierStub.respond(path: "/roster/log", body: logDocument())
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r2", policy: "br-policy v3")), answer())
        
        #expect(report.policy == .unverifiable(.policySuperseded))
        #expect(report.placement == .unverifiable(.policyUnverified))
    }
    
    @Test
    func logThatDoesNotHashToTheCheckpointIsAMismatch() async throws {
        try serve(roster: "r2", policy: "br-policy v3")
        try VerifierStub.respond(path: "/roster/log", body: logDocument(events: 6))
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r2", policy: "br-policy v3")), answer())
        
        #expect(report.policy == .invalid(.logMismatch))
    }
    
    @Test
    func logEventIndexOutsideThirtyOneBitsIsAParseError() async throws {
        try serve(roster: "r2", policy: "br-policy v3")
        var document = try #require(JSONSerialization.jsonObject(with: logDocument()) as? [String: Any])
        var events = try #require(document["events"] as? [[String: Any]])
        events[0]["index"] = 2_147_483_648
        document["events"] = events
        try VerifierStub.respond(path: "/roster/log", body: json(document))
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r2", policy: "br-policy v3")), answer())
        
        #expect(report.policy == .unverifiable(.parseError))
    }
    
    @Test
    func checkpointOverTheLogLimitIsNotFetched() async throws {
        try VerifierStub.respond(path: "/roster", body: json(roster("r2", checkpointSize: 4097)))
        try VerifierStub.respond(path: "/policy/routing", body: json(policyBundle("br-policy v3")))
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r2", policy: "br-policy v3")), answer())
        
        #expect(report.policy == .unverifiable(.logTooLarge))
        #expect(!VerifierStub.requestedPaths.contains("/roster/log"))
    }
    
    @Test
    func malformedEventPastTheCheckpointIsAParseError() async throws {
        try serve(roster: "r2", policy: "br-policy v3")
        var document = try #require(JSONSerialization.jsonObject(with: logDocument()) as? [String: Any])
        var events = try #require(document["events"] as? [[String: Any]])
        // r2 signs the first 7 leaves; event 7 is past its checkpoint.
        events[7]["recordedAt"] = "not a time"
        document["events"] = events
        try VerifierStub.respond(path: "/roster/log", body: json(document))
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r2", policy: "br-policy v3")), answer())
        
        #expect(report.policy == .unverifiable(.parseError))
    }
    
    @Test
    func policyLoggedOnlyPastTheCheckpointIsNewerEvenWithALaterVersionWithinIt() throws {
        let served = servedPolicy()
        let later = try TransparencyLogEvent(index: 0, type: "POLICY_PUBLISH", homeserverId: "br-policy:v4", payloadHash: "",
                                             recordedAt: #require(ResolverInstant(iso: "2026-10-05T00:00:00Z")))
        let own = try TransparencyLogEvent(index: 1, type: "POLICY_PUBLISH", homeserverId: "br-policy:v3", payloadHash: served.contentHash,
                                           recordedAt: #require(ResolverInstant(iso: "2026-10-06T00:00:00Z")))
        let checkpoint = try RosterLogCheckpoint(merkleRoot: #require(MerkleTree.root(leafHashes: [later.leafHash])), size: 1)
        
        #expect(ResolverVerifier.logOutcome(for: served, checkpoint: checkpoint, events: [later, own]) == .unverifiable(.policyNewerThanCheckpoint))
    }
    
    @Test
    func existingAccountIsIndeterminateEvenWhenTheReproductionWouldMatch() async throws {
        try serve(roster: "r1")
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r1")), answer(exists: true))
        
        #expect(report.placement == .indeterminate(.existingAccount))
        #expect(report.overall == .unverifiable(.placement))
    }
    
    @Test
    func otherEntryAtTheSameRosterVersionIsAMismatch() async throws {
        try serve(roster: "r2", policy: "br-policy v3")
        // The policy does not route this number and the fallback places it on hs-ca.
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r2", policy: "br-policy v3")),
                                        answer(.br, rosterVersion: 7), phone: "+5519991112222")
        
        #expect(report.placement == .mismatch)
        #expect(report.overall == .failed(.placement))
    }
    
    @Test
    func otherEntryAtAnotherRosterVersionIsUnattributed() async throws {
        try serve(roster: "r2", policy: "br-policy v3")
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r2", policy: "br-policy v3")),
                                        answer(.br, rosterVersion: 6), phone: "+5519991112222")
        
        #expect(report.placement == .indeterminate(.unattributed))
    }
    
    @Test
    func otherEntryWithoutARosterVersionIsUnattributed() async throws {
        try serve(roster: "r2", policy: "br-policy v3")
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r2", policy: "br-policy v3")),
                                        answer(.br), phone: "+5519991112222")
        
        #expect(report.placement == .indeterminate(.unattributed))
    }
    
    @Test
    func sameEntryAsTheReproductionIsAMatch() async throws {
        try serve(roster: "r2", policy: "br-policy v3")
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r2", policy: "br-policy v3")),
                                        answer(.ca), phone: "+5519991112222")
        
        #expect(report.placement == .match)
    }
    
    @Test
    func noPlacementAtTheSameRosterVersionIsAMismatch() async throws {
        try serveRosterAcceptingNoNewAccounts()
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r1")), answer(rosterVersion: 3))
        
        #expect(report.placement == .mismatch)
    }
    
    @Test
    func noPlacementWithoutARosterVersionIsUnattributed() async throws {
        try serveRosterAcceptingNoNewAccounts()
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r1")), answer())
        
        #expect(report.placement == .indeterminate(.unattributed))
    }
    
    @Test
    func ruleHiddenByAMissingDelegateSignatureIsIndeterminate() async throws {
        try serve(roster: "r2", policy: "br-policy v3")
        // na-zone has no delegate signature, so its rule for +1 is skipped and the fallback decides.
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r2", policy: "br-policy v3")),
                                        answer(.ca, rosterVersion: 7), phone: "+14165550123")
        
        #expect(report.placement == .indeterminate(.unsignedRule))
    }
    
    @Test
    func noPlacementPastTheFallbackLimitAtTheSameRosterVersionIsAMismatch() async throws {
        try serve(roster: "r9", policy: "br-policy v3")
        // No rule routes this number, and r9's candidates weigh one past 2^24. Without the limit the fallback would pick hs-over.
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r9", policy: "br-policy v3")),
                                        answer(.over, rosterVersion: 7), phone: "+5521990000000")
        
        #expect(report.placement == .mismatch)
    }
    
    @Test
    func noPlacementPastTheFallbackLimitWithoutARosterVersionIsUnattributed() async throws {
        try serve(roster: "r9", policy: "br-policy v3")
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r9", policy: "br-policy v3")),
                                        answer(.over), phone: "+5521990000000")
        
        #expect(report.placement == .indeterminate(.unattributed))
    }
    
    @Test
    func unsignedRuleAboveNoPlacementPastTheFallbackLimitIsIndeterminate() async throws {
        let policy = "br-policy v3 without the sp-zone delegate signature"
        try serve(roster: "r9", policy: policy)
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r9", policy: policy)), answer(.over, rosterVersion: 7))
        
        #expect(report.placement == .indeterminate(.unsignedRule))
    }
    
    @Test
    func reportLineMatchesTheContract() {
        let report = ResolverVerificationReport(environment: "dev", rosterVersion: 4, rosterForm: "v1", rosterSignature: .valid,
                                                homeserverMatch: .activeMatch, memberEntry: .unattested, logConsistency: .consistent,
                                                policy: .valid, placement: .indeterminate(.existingAccount), durationMs: 640)
        let expected = ["environment=dev", "rosterVersion=4", "rosterForm=v1", "rosterSignature=valid", "homeserverMatch=ACTIVE_MATCH",
                        "memberEntry=unattested", "logConsistency=consistent", "policy=valid", "placement=indeterminate(existing_account)",
                        "overall=unverifiable(placement)", "durationMs=640"]
        
        #expect(report.logDescription == expected.joined(separator: " "))
    }
    
    @Test
    func hungRosterTimesOutWithinTheBudget() async throws {
        VerifierStub.hangs = true
        let started = ContinuousClock.now
        let report = try await verified(makeVerifier(trustRoots: trustRoots(ofRoster: "r1"), budget: .milliseconds(300)), answer())
        let elapsed = ContinuousClock.now - started
        
        #expect(report == stopped(rosterSignature: .unverifiable(.timeout), durationMs: report.durationMs))
        #expect(elapsed < .seconds(5))
        #expect((250..<5000).contains(report.durationMs), "durationMs \(report.durationMs)")
    }
    
    @Test
    func resolveAnswerWithoutExistsIsRefused() async throws {
        let client = ResolverClient(baseURL: baseURL, session: stubSession())
        try VerifierStub.respond(path: "/resolve", body: json(["registerAt": ["serverName": "br.gua.test", "baseUrl": "https://matrix.br.gua.test"]]))
        
        do {
            _ = try await client.resolve(phoneNumber: Self.phone)
            Issue.record("an answer without exists was accepted")
        } catch let error as ResolverError {
            guard case .decoding = error else {
                Issue.record("expected a decoding error, got \(error)")
                return
            }
        }
    }
    
    @Test
    func resolveAnswerCarriesItsRosterVersion() async throws {
        let client = ResolverClient(baseURL: baseURL, session: stubSession())
        let ref: [String: Any] = ["serverName": "br.gua.test", "baseUrl": "https://matrix.br.gua.test"]
        
        try VerifierStub.respond(path: "/resolve", body: json(["exists": false, "registerAt": ref, "rosterVersion": 7]))
        let versioned = try await client.resolve(phoneNumber: Self.phone)
        #expect(versioned.rosterVersion == 7)
        
        try VerifierStub.respond(path: "/resolve", body: json(["exists": false, "registerAt": ref]))
        let unversioned = try await client.resolve(phoneNumber: Self.phone)
        #expect(unversioned.rosterVersion == nil)
    }
    
    @Test
    func malformedRosterVersionDoesNotFailTheResolve() async throws {
        let client = ResolverClient(baseURL: baseURL, session: stubSession())
        let ref: [String: Any] = ["serverName": "br.gua.test", "baseUrl": "https://matrix.br.gua.test"]
        
        try VerifierStub.respond(path: "/resolve", body: json(["exists": false, "registerAt": ref, "rosterVersion": "seven"]))
        let resolution = try await client.resolve(phoneNumber: Self.phone)
        
        #expect(resolution.rosterVersion == nil)
        #expect(resolution.homeserver.serverName == "br.gua.test")
    }
    
    @Test
    func startVerificationReturnsBeforeTheReportExists() async throws {
        VerifierStub.hangs = true
        let verifier = try makeVerifier(trustRoots: trustRoots(ofRoster: "r1"), budget: .seconds(1))
        
        verifier.startVerification(of: answer(), phoneNumber: Self.phone)
        
        #expect(verifier.lastReport == nil)
        let deadline = ContinuousClock.now + .seconds(10)
        while verifier.lastReport == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(verifier.lastReport?.rosterSignature == .unverifiable(.timeout), "the hung roster request times out inside the budget")
    }
    
    @Test
    func signInProceedsWhileVerificationIsStillRunning() async throws {
        VerifierStub.hangs = true
        let verifier = try makeVerifier(trustRoots: trustRoots(ofRoster: "r1"), budget: .seconds(5))
        let appMediator = AppMediatorMock(.init())
        (appMediator.windowManager as? WindowManagerMock)?.mainWindow = UIWindow()
        let navigationRootCoordinator = NavigationRootCoordinator()
        let oAuthPresenter = OAuthPresenterFake()
        let flowCoordinator = AuthenticationFlowCoordinator(authenticationService: AuthenticationService.mock,
                                                            bugReportService: BugReportServiceMock(.init()),
                                                            navigationRootCoordinator: navigationRootCoordinator,
                                                            appMediator: appMediator,
                                                            appSettings: AppSettings.volatile(),
                                                            appHooks: AppHooks(),
                                                            userIndicatorController: UserIndicatorControllerMock(),
                                                            resolverClient: ResolverClientFake(resolution: mockServiceAnswer),
                                                            resolverVerifier: verifier,
                                                            usesPhoneLoginHint: true) { _ in oAuthPresenter }
        defer { oAuthPresenter.finish() }
        
        flowCoordinator.start()
        let navigationStackCoordinator = try #require(navigationRootCoordinator.rootCoordinator as? NavigationStackCoordinator)
        let phoneEntry = try #require(navigationStackCoordinator.rootCoordinator as? PhoneEntryScreenCoordinator)
        phoneEntry.viewModel.context.localPhoneNumber = "5551234567"
        
        let (requests, requestContinuation) = AsyncStream<String>.makeStream()
        VerifierStub.onRequest = { requestContinuation.yield($0) }
        let rosterRequested = deferFulfillment(requests, timeout: .seconds(5), message: "the verifier asked for the roster") { $0 == "/roster" }
        let signInStarted = deferFulfillment(oAuthPresenter.authenticationStarted) { _ in true }
        phoneEntry.viewModel.context.send(viewAction: .continueTapped)
        try await signInStarted.fulfill()
        
        #expect(verifier.lastReport == nil, "sign-in reached the web session while the roster request was still hanging")
        // The detached fetch starts asynchronously; wait for it before reading the requested paths.
        try await rosterRequested.fulfill()
        #expect(VerifierStub.requestedPaths == ["/roster"])
    }
    
    private enum Homeserver {
        case br, ca, over
        
        var answer: ResolvedHomeserver {
            switch self {
            case .br: ResolvedHomeserver(serverName: "br.gua.test", baseURL: "https://matrix.br.gua.test", masIssuer: "https://account.br.gua.test", region: "BR")
            case .ca: ResolvedHomeserver(serverName: "ca.gua.test", baseURL: "https://matrix.ca.gua.test", masIssuer: "https://account.ca.gua.test", region: nil)
            case .over: ResolvedHomeserver(serverName: "over.gua.test", baseURL: "https://matrix.over.gua.test", masIssuer: "https://account.over.gua.test", region: nil)
            }
        }
    }
    
    private func answer(_ homeserver: Homeserver = .br, exists: Bool = false, rosterVersion: Int64? = nil) -> HomeserverResolution {
        var resolution = HomeserverResolution(exists: exists, homeserver: homeserver.answer)
        resolution.rosterVersion = rosterVersion
        return resolution
    }
    
    /// The homeserver the mocked authentication service configures.
    private var mockServiceAnswer: HomeserverResolution {
        HomeserverResolution(exists: true, homeserver: ResolvedHomeserver(serverName: "matrix.org", baseURL: "matrix.org", masIssuer: nil, region: nil))
    }
    
    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VerifierStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
    
    private func makeVerifier(trustRoots: ResolverTrustRoots, budget: Duration = .seconds(10), isEnabled: Bool = true) -> ResolverVerifier {
        let now = now
        let wallClock: @Sendable () -> Int64 = { now }
        let enabled: @Sendable () -> Bool = { isEnabled }
        return ResolverVerifier(baseURL: baseURL, trustRoots: trustRoots, environment: "test", checkpointStore: checkpoints,
                                session: stubSession(), budget: budget, now: wallClock, isEnabled: enabled)
    }
    
    private func verified(_ verifier: ResolverVerifier, _ resolution: HomeserverResolution,
                          phone: String = ResolverVerifierTests.phone) async throws -> ResolverVerificationReport {
        let report = await verifier.verify(resolution: resolution, phoneNumber: phone)
        return try #require(report)
    }
    
    private func stopped(rosterForm: String? = nil, rosterSignature: ResolverVerificationReport.RosterSignature,
                         others reason: ResolverVerificationReason = .rosterUnverified, durationMs: Int) -> ResolverVerificationReport {
        ResolverVerificationReport(environment: "test", rosterVersion: nil, rosterForm: rosterForm, rosterSignature: rosterSignature,
                                   homeserverMatch: .unverifiable(reason), memberEntry: .unverifiable(reason), logConsistency: .unverifiable(reason),
                                   policy: .unverifiable(reason), placement: .unverifiable(reason), durationMs: durationMs)
    }
    
    private func servedPolicy() -> ServedPolicy {
        let hash = (log["events"] as? [[String: Any]] ?? []).first { $0["homeserverId"] as? String == "br-policy:v3" }?["payloadHash"] as? String
        return ServedPolicy(policyId: "br-policy", version: 3, contentHash: hash ?? "")
    }
    
    private func spki(_ keyName: String) throws -> String {
        let keys = try #require(vectors["keys"] as? [String: [String: Any]])
        return try #require(keys[keyName]?["publicKeySpkiB64"] as? String)
    }
    
    /// Counting the top-level object, the ignored field nests `depth + 1` levels deep.
    private func rosterJSONText(_ ref: String, ignoredFieldNesting depth: Int) throws -> String {
        let roster = try #require(String(bytes: json(rosterJSON(ref)), encoding: .utf8))
        return "{\"pad\":" + String(repeating: "[", count: depth) + String(repeating: "]", count: depth) + "," + roster.dropFirst()
    }
    
    private func serveRosterAcceptingNoNewAccounts() throws {
        let roster = try editing(rosterJSON("r1"), entry: 0) { entry in
            var homeserver = entry["homeserver"] as? [String: Any] ?? [:]
            homeserver["acceptsNew"] = false
            entry["homeserver"] = homeserver
        }
        try VerifierStub.respond(path: "/roster", body: json(signed(roster)))
        try VerifierStub.respond(path: "/roster/log", body: logDocument())
    }
    
    private func instant(_ iso: String) throws -> Int64 {
        try #require(ResolverInstant(iso: iso)).epochMilliseconds
    }
    
    private func section(_ name: String) -> [[String: Any]] {
        vectors[name] as? [[String: Any]] ?? []
    }
    
    private func vector(_ name: String, ref: String) throws -> [String: Any] {
        try #require(section(name).first { $0["ref"] as? String == ref }, "no \(name) vector \(ref)")
    }
    
    private func vector(_ sectionName: String, named name: String) throws -> [String: Any] {
        try #require(section(sectionName).first { $0["name"] as? String == name }, "no \(sectionName) vector named \(name)")
    }
    
    private func rosterJSON(_ ref: String) throws -> [String: Any] {
        try #require(vector("rosters", ref: ref)["roster"] as? [String: Any])
    }
    
    private func policyBundle(_ ref: String) throws -> [String: Any] {
        try #require(vector("policies", ref: ref)["bundle"] as? [String: Any])
    }
    
    private var log: [String: Any] {
        vectors["log"] as? [String: Any] ?? [:]
    }
    
    private func logRoot(size: Int) -> String {
        (log["roots"] as? [[String: Any]] ?? []).first { $0["size"] as? Int == size }?["rootHex"] as? String ?? ""
    }
    
    private func checkpoint(size: Int) -> RosterLogCheckpoint {
        RosterLogCheckpoint(merkleRoot: logRoot(size: size), size: size)
    }
    
    private func proofDocument(first: Int, second: Int) throws -> Data {
        let proof = (log["consistencyProofs"] as? [[String: Any]] ?? [])
            .first { $0["first"] as? Int == first && $0["second"] as? Int == second }?["proof"] as? [String]
        return try json(["first": first, "second": second, "proof": #require(proof)])
    }
    
    private func logDocument(events count: Int? = nil) throws -> Data {
        let events = (log["events"] as? [[String: Any]] ?? []).map { event in
            ["index": event["index"] as Any, "type": event["type"] as Any, "homeserverId": event["homeserverId"] as Any,
             "payloadHash": event["payloadHash"] as Any, "recordedAt": event["recordedAt"] as Any]
        }
        return try json(["events": Array(events.prefix(count ?? events.count))])
    }
    
    /// Without a named policy, `/policy/routing` answers 404.
    private func serve(roster ref: String, policy: String? = nil) throws {
        try VerifierStub.respond(path: "/roster", body: json(rosterJSON(ref)))
        try VerifierStub.respond(path: "/roster/log", body: logDocument())
        if let policy {
            try VerifierStub.respond(path: "/policy/routing", body: json(policyBundle(policy)))
        }
    }
    
    private func trustRoots(ofRoster ref: String, policy policyRef: String? = nil) throws -> ResolverTrustRoots {
        try trustRoots(of: vector("rosters", ref: ref), policy: policyRef)
    }
    
    private func trustRoots(of rosterVector: [String: Any], policy policyRef: String? = nil) throws -> ResolverTrustRoots {
        let policyKeys = try policyRef.map { try keys(vector("policies", ref: $0)["trustedKeys"]) } ?? []
        return ResolverTrustRoots(authorityKeys: keys(rosterVector["trustedKeys"]), authorityThreshold: 1,
                                  policyKeys: policyKeys, policyThreshold: 1)
    }
    
    private func keys(_ any: Any?) -> [ResolverTrustedKey] {
        (any as? [[String: Any]] ?? []).map { ResolverTrustedKey(id: $0["id"] as? String ?? "", publicKey: $0["publicKeySpkiB64"] as? String ?? "") }
    }
    
    private func editing(_ roster: [String: Any], entry index: Int, _ change: (inout [String: Any]) -> Void) throws -> [String: Any] {
        var entries = try #require(roster["entries"] as? [[String: Any]])
        change(&entries[index])
        var roster = roster
        roster["entries"] = entries
        return roster
    }
    
    private func roster(_ ref: String, checkpointSize size: Int) throws -> [String: Any] {
        var roster = try rosterJSON(ref)
        roster["logCheckpoint"] = ["merkleRoot": logRoot(size: size), "size": size]
        return try signed(roster)
    }
    
    /// rfc8032-test1 is the key the vectors trust as authority-a.
    private func signed(_ roster: [String: Any]) throws -> [String: Any] {
        let document = try JSONDecoder().decode(SignedRosterDocument.self, from: json(roster))
        let canonical = try #require(CanonicalRoster.form(of: document).flatMap { CanonicalRoster.bytes(of: document, form: $0) })
        var roster = roster
        roster["authoritySignatures"] = try [["authorityKeyId": "authority-a", "signatureB64": sign(canonical, with: "rfc8032-test1")]]
        return roster
    }
    
    /// rfc8032-test-sha-abc is the key the vectors use as hs-br-1.
    private func memberSignature(of entry: [String: Any]) throws -> String {
        let homeserver = try JSONDecoder().decode(RosterHomeserver.self, from: json(entry["homeserver"]))
        let member = try JSONDecoder().decode(RosterMemberAttestation.self, from: json(entry["member"]))
        let canonical = try CanonicalMemberEntry.bytes(homeserver: homeserver, member: member,
                                                       notBefore: instant(#require(member.notBefore)), notAfter: instant(#require(member.notAfter)))
        return try sign(canonical, with: "rfc8032-test-sha-abc")
    }
    
    private func withMemberSignature(_ entry: [String: Any], _ signature: String) -> [String: Any] {
        var entry = entry
        var member = entry["member"] as? [String: Any] ?? [:]
        member["signatures"] = [["keyId": member["keyId"] as Any, "signatureB64": signature]]
        entry["member"] = member
        return entry
    }
    
    private func sign(_ message: [UInt8], with keyName: String) throws -> String {
        let keys = try #require(vectors["keys"] as? [String: [String: Any]])
        let seedHex = try #require(keys[keyName]?["seedHex"] as? String)
        let seed = try #require(ResolverVerificationHex.bytes(seedHex))
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed).signature(for: message).base64EncodedString()
    }
    
    private func json(_ object: Any?) throws -> Data {
        try JSONSerialization.data(withJSONObject: object as Any, options: .sortedKeys)
    }
}

private final nonisolated class InMemoryCheckpointStore: ResolverCheckpointStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var checkpoints = [URL: RosterLogCheckpoint]()
    private var writeCount = 0
    var failsReads = false
    
    var writes: Int {
        lock.withLock { writeCount }
    }
    
    func checkpoint(for baseURL: URL) throws -> RosterLogCheckpoint? {
        try lock.withLock {
            if failsReads {
                throw CocoaError(.fileReadUnknown)
            }
            return checkpoints[baseURL]
        }
    }
    
    func store(_ checkpoint: RosterLogCheckpoint, for baseURL: URL) throws {
        lock.withLock {
            checkpoints[baseURL] = checkpoint
            writeCount += 1
        }
    }
}

private final class ResolverClientFake: ResolverClientProtocol, @unchecked Sendable {
    private let resolution: HomeserverResolution
    
    init(resolution: HomeserverResolution) {
        self.resolution = resolution
    }
    
    func resolve(phoneNumber: String) async throws -> HomeserverResolution {
        resolution
    }
}

@MainActor
private final class OAuthPresenterFake: OAuthAuthenticationPresenterProtocol {
    let authenticationStarted = PassthroughSubject<Void, Never>()
    private var pendingAuthentication: CheckedContinuation<Void, Never>?
    
    func authenticate(using oAuthData: OAuthAuthorizationDataProxy) async -> Result<UserSessionProtocol, AuthenticationServiceError> {
        await withCheckedContinuation { continuation in
            pendingAuthentication = continuation
            authenticationStarted.send(())
        }
        return .failure(.oAuthError(.userCancellation))
    }
    
    func handleUniversalLinkCallback(_ url: URL) { }
    
    func cancel() { }
    
    func finish() {
        pendingAuthentication?.resume()
        pendingAuthentication = nil
    }
}

private nonisolated enum VerifierStub {
    struct Response {
        let status: Int
        let body: Data
        let delay: TimeInterval
    }
    
    enum Behaviour {
        case respond(Response)
        case fail
        case hang
    }
    
    private static let lock = NSLock()
    private nonisolated(unsafe) static var queues = [String: [Response]]()
    private nonisolated(unsafe) static var paths = [String]()
    private nonisolated(unsafe) static var queries = [String: String]()
    private nonisolated(unsafe) static var failure = false
    private nonisolated(unsafe) static var hanging = false
    private nonisolated(unsafe) static var requestObserver: (@Sendable (String) -> Void)?
    
    static var requestedPaths: [String] {
        lock.withLock { paths }
    }
    
    static var requestedQueries: [String: String] {
        lock.withLock { queries }
    }
    
    static var failsTransport: Bool {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }
    
    static var hangs: Bool {
        get { lock.withLock { hanging } }
        set { lock.withLock { hanging = newValue } }
    }
    
    static var onRequest: (@Sendable (String) -> Void)? {
        get { lock.withLock { requestObserver } }
        set { lock.withLock { requestObserver = newValue } }
    }
    
    static func respond(path: String, status: Int, body: String) {
        respond(path: path, status: status, body: Data(body.utf8))
    }
    
    /// Serves `body` to every matching request until replaced.
    static func respond(path: String, query: String? = nil, status: Int = 200, body: Data, delay: TimeInterval = 0) {
        lock.withLock { queues[key(path, query)] = [Response(status: status, body: body, delay: delay)] }
    }
    
    /// Serves the queued bodies one request each, then repeats the last.
    static func enqueue(path: String, body: Data) {
        lock.withLock { queues[path, default: []].append(Response(status: 200, body: body, delay: 0)) }
    }
    
    static func reset() {
        lock.withLock {
            queues = [:]
            paths = []
            queries = [:]
            failure = false
            hanging = false
            requestObserver = nil
        }
    }
    
    static func receive(_ url: URL) -> Behaviour {
        let (behaviour, observer) = lock.withLock { () -> (Behaviour, (@Sendable (String) -> Void)?) in
            paths.append(url.path)
            if let query = url.query {
                queries[url.path] = query
            }
            if hanging {
                return (.hang, requestObserver)
            }
            if failure {
                return (.fail, requestObserver)
            }
            let exact = key(url.path, url.query)
            let lookup = queues[exact] != nil ? exact : url.path
            guard let queued = queues[lookup], let next = queued.first else {
                return (.respond(Response(status: 404, body: Data(), delay: 0)), requestObserver)
            }
            if queued.count > 1 {
                queues[lookup] = Array(queued.dropFirst())
            }
            return (.respond(next), requestObserver)
        }
        observer?(url.path)
        return behaviour
    }
    
    private static func key(_ path: String, _ query: String?) -> String {
        query.map { "\(path)?\($0)" } ?? path
    }
}

private nonisolated class VerifierStubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }
    
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }
    
    override func startLoading() {
        guard let url = request.url else { return }
        switch VerifierStub.receive(url) {
        case .hang:
            return
        case .fail:
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        case .respond(let response):
            nonisolated(unsafe) let deliver = { [weak self] in
                guard let self, let httpResponse = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: nil,
                                                                   headerFields: ["Content-Type": "application/json"]) else { return }
                client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: response.body)
                client?.urlProtocolDidFinishLoading(self)
            }
            if response.delay > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + response.delay) { deliver() }
            } else {
                deliver()
            }
        }
    }
    
    override func stopLoading() { }
}
