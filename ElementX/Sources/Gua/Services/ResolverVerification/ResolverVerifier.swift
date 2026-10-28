//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import CryptoKit
import Foundation

protocol ResolverVerifying: Sendable {
    /// Verifies a `/resolve` answer detached from the caller. The outcome is logged and never changes what the
    /// app connects to; the call returns at once and never throws.
    func startVerification(of resolution: HomeserverResolution, phoneNumber: String)
}

/// Report-only verification of the resolver's answer against its signed artifacts: the roster under the pinned
/// authority keys, the returned homeserver as an ACTIVE entry, the member self-signature, the log checkpoint
/// against the last one accepted, the routing policy when served, and the placement reproduced locally.
final class ResolverVerifier: ResolverVerifying, @unchecked Sendable {
    private let baseURL: URL
    private let trustRoots: ResolverTrustRoots
    private let environment: String
    private let appSettings: AppSettings
    private let session: URLSession
    private let checkpointStore: ResolverCheckpointStoring
    private let budget: TimeInterval
    private let clock: @Sendable () -> Int64
    private let authorityKeys: [String: Curve25519.Signing.PublicKey]
    private let policyKeys: [String: Curve25519.Signing.PublicKey]

    private let lock = NSLock()
    private var storedReport: ResolverVerificationReport?

    /// The most recent report, for tests and diagnostics.
    var lastReport: ResolverVerificationReport? {
        lock.withLock { storedReport }
    }

    init(baseURL: URL,
         trustRoots: ResolverTrustRoots,
         environment: String,
         appSettings: AppSettings,
         checkpointStore: ResolverCheckpointStoring = UserDefaultsResolverCheckpointStore(),
         session: URLSession? = nil,
         budget: TimeInterval = 10,
         clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.baseURL = baseURL
        self.trustRoots = trustRoots
        self.environment = environment
        self.appSettings = appSettings
        self.checkpointStore = checkpointStore
        self.budget = budget
        self.clock = clock
        authorityKeys = ResolverSignatureCounter.keys(trustRoots.authorityKeys)
        policyKeys = ResolverSignatureCounter.keys(trustRoots.policyKeys)
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = budget
            configuration.timeoutIntervalForResource = budget
            self.session = URLSession(configuration: configuration)
        }
    }

    /// Convenience initializer for the app. Returns `nil` when the deployment has no resolver.
    convenience init?(appSettings: AppSettings) {
        let deployment = GuaDeployment.current
        guard let baseURL = deployment.resolverBaseURL else { return nil }
        self.init(baseURL: baseURL, trustRoots: deployment.resolverTrustRoots,
                  environment: deployment == .production ? "prod" : "dev",
                  appSettings: appSettings)
    }

    var isEnabled: Bool {
        appSettings.guaResolverVerificationEnabled
    }

    func startVerification(of resolution: HomeserverResolution, phoneNumber: String) {
        guard isEnabled else { return }
        Task.detached(priority: .utility) { [self] in
            _ = await verify(resolution: resolution, phoneNumber: phoneNumber)
        }
    }

    /// Runs every check and returns the report, or `nil` when the kill switch is off.
    func verify(resolution: HomeserverResolution, phoneNumber: String) async -> ResolverVerificationReport? {
        guard isEnabled else { return nil }
        let started = Date()
        var draft = Draft()
        await run(resolution: resolution, phoneNumber: phoneNumber, deadline: started.addingTimeInterval(budget), draft: &draft)
        let report = draft.report(environment: environment, durationMs: Int(Date().timeIntervalSince(started) * 1000))
        lock.withLock { storedReport = report }
        MXLog.info("Resolver verification \(report.logDescription)")
        return report
    }

    // MARK: - Checks

    private func run(resolution: HomeserverResolution, phoneNumber: String, deadline: Date, draft: inout Draft) async {
        guard trustRoots.hasAuthorityKeys else {
            draft.failEarly(.unverifiable(reason: "no_trust_roots"), reason: "no_trust_roots")
            return
        }
        guard !authorityKeys.isEmpty else {
            draft.failEarly(.unverifiable(reason: "crypto_unsupported"), reason: "crypto_unsupported")
            return
        }

        let roster: SignedRosterDocument
        let malformedMembers: Set<Int>
        do {
            let data = try await fetch("/roster", deadline: deadline)
            guard let flagged = StrictJSONScanner.entriesWithDuplicateMemberKeys(in: data) else {
                draft.failEarly(.unverifiable(reason: "parse_error"), reason: "parse_error")
                return
            }
            malformedMembers = flagged
            roster = try JSONDecoder().decode(SignedRosterDocument.self, from: data)
        } catch is DecodingError {
            draft.failEarly(.unverifiable(reason: "parse_error"), reason: "parse_error")
            return
        } catch let error as FetchError {
            draft.failEarly(.unverifiable(reason: error.rosterReason), reason: error.rosterReason)
            return
        } catch {
            draft.failEarly(.unverifiable(reason: "roster_unavailable"), reason: "roster_unavailable")
            return
        }
        draft.rosterVersion = roster.version

        guard let form = CanonicalRoster.form(of: roster) else {
            draft.rosterForm = "mixed"
            draft.failEarly(.unverifiable(reason: "mixed_roster_form"), reason: "mixed_roster_form")
            return
        }
        draft.rosterForm = form.rawValue
        guard let canonical = CanonicalRoster.bytes(of: roster, form: form) else {
            draft.failEarly(.unverifiable(reason: "parse_error"), reason: "parse_error")
            return
        }

        let count = ResolverSignatureCounter.count(signatures: roster.authoritySignatures.map { ($0.authorityKeyId, $0.signatureB64) },
                                                   over: canonical, keys: authorityKeys)
        guard count.valid >= trustRoots.authorityThreshold else {
            let reason = count.known == 0 ? "unknown_key_id" : count.valid == 0 ? "bad_signature" : "threshold_not_met"
            draft.failEarly(.invalid(reason: reason), reason: "roster_unverified")
            return
        }
        draft.rosterSignature = .valid

        let answer = resolution.homeserver
        draft.homeserverMatch = Self.locate(serverName: answer.serverName, baseUrl: answer.baseURL, masIssuer: answer.masIssuer, in: roster)
        draft.memberEntry = memberEntry(for: answer, in: roster, malformedMembers: malformedMembers)
        draft.logConsistency = await logConsistency(of: roster.logCheckpoint, deadline: deadline)

        let policy = await verifyPolicy(roster: roster, deadline: deadline)
        draft.policy = policy.outcome

        draft.placement = await placement(resolution: resolution, phoneNumber: phoneNumber, roster: roster, policy: policy)
    }

    /// How the answer relates to the roster. Only an ACTIVE entry with exactly these fields may be connected to:
    /// a known server name with another base URL or issuer is the shape of a redirect to another host.
    static func locate(serverName: String, baseUrl: String, masIssuer: String?, in roster: SignedRosterDocument) -> ResolverVerificationReport.HomeserverMatch {
        var best = ResolverVerificationReport.HomeserverMatch.notInRoster
        for entry in roster.entries where entry.homeserver.serverName == serverName {
            let sameEndpoint = entry.homeserver.baseUrl == baseUrl && entry.homeserver.masIssuer == masIssuer
            if sameEndpoint, entry.isActive { return .activeMatch }
            best = sameEndpoint ? .inactive : .fieldMismatch
        }
        return best
    }

    private func memberEntry(for answer: ResolvedHomeserver, in roster: SignedRosterDocument, malformedMembers: Set<Int>) -> ResolverVerificationReport.MemberEntry {
        guard let index = roster.entries.firstIndex(where: {
            $0.homeserver.serverName == answer.serverName && $0.homeserver.baseUrl == answer.baseURL && $0.homeserver.masIssuer == answer.masIssuer
        }) else {
            return .unverifiable
        }
        let entry = roster.entries[index]
        if entry.memberIsMalformed || malformedMembers.contains(index) { return .invalid(reason: "parse_error") }
        switch MemberEntryVerifier.verify(homeserver: entry.homeserver, member: entry.member, atEpochMilliseconds: clock()) {
        case .valid: return .valid
        case .unattested: return .unattested
        case .invalid(let reason): return .invalid(reason: reason)
        }
    }

    private func logConsistency(of served: RosterLogCheckpoint, deadline: Date) async -> ResolverVerificationReport.LogConsistency {
        guard let pinned = checkpointStore.checkpoint(for: baseURL), pinned.size > 0 else {
            checkpointStore.store(served, for: baseURL)
            return .firstSeen
        }
        if served.size == pinned.size {
            return served.merkleRoot == pinned.merkleRoot ? .consistent : .inconsistent
        }
        if served.size < pinned.size { return .rollback }
        guard pinned.size <= Int.max, served.size <= Int.max else { return .unverifiable(reason: "parse_error") }
        let proof: ConsistencyProofDocument
        do {
            let data = try await fetch("/roster/log/consistency",
                                       query: [URLQueryItem(name: "first", value: String(pinned.size)), URLQueryItem(name: "second", value: String(served.size))],
                                       deadline: deadline)
            proof = try JSONDecoder().decode(ConsistencyProofDocument.self, from: data)
        } catch is DecodingError {
            return .unverifiable(reason: "parse_error")
        } catch {
            return .unverifiable(reason: (error as? FetchError)?.logReason ?? "log_unavailable")
        }
        guard MerkleTree.verifyConsistency(first: Int(pinned.size), second: Int(served.size),
                                           oldRoot: pinned.merkleRoot, newRoot: served.merkleRoot, proof: proof.proof) else {
            return .inconsistent
        }
        checkpointStore.store(served, for: baseURL)
        return .consistent
    }

    private struct PolicyResult {
        let outcome: ResolverVerificationReport.Policy
        let verified: VerifiedRoutingPolicy?
    }

    private func verifyPolicy(roster: SignedRosterDocument, deadline: Date) async -> PolicyResult {
        let bundle: RoutingPolicyBundle
        do {
            let data = try await fetch("/policy/routing", deadline: deadline)
            bundle = try JSONDecoder().decode(RoutingPolicyBundle.self, from: data)
        } catch FetchError.status(404) {
            return PolicyResult(outcome: .notPresent, verified: nil)
        } catch is DecodingError {
            return PolicyResult(outcome: .unverifiable(reason: "parse_error"), verified: nil)
        } catch {
            return PolicyResult(outcome: .unverifiable(reason: (error as? FetchError)?.policyReason ?? "policy_unavailable"), verified: nil)
        }
        guard !trustRoots.policyKeys.isEmpty else { return PolicyResult(outcome: .unverifiable(reason: "no_policy_keys"), verified: nil) }
        guard !policyKeys.isEmpty else { return PolicyResult(outcome: .unverifiable(reason: "crypto_unsupported"), verified: nil) }
        guard let canonical = CanonicalRoutingPolicy.bytes(of: bundle) else {
            return PolicyResult(outcome: .unverifiable(reason: "parse_error"), verified: nil)
        }
        let count = RoutingPolicyVerifier.validSignatureCount(of: bundle, canonical: canonical, keys: policyKeys)
        guard count.valid >= trustRoots.policyThreshold else {
            let reason = count.known == 0 ? "unknown_key_id" : count.valid == 0 ? "bad_signature" : "threshold_not_met"
            return PolicyResult(outcome: .invalid(reason: reason), verified: nil)
        }
        if let failure = await policyPublishFailure(contentHash: ResolverVerificationCrypto.sha256Hex(canonical),
                                                    checkpoint: roster.logCheckpoint, deadline: deadline) {
            return PolicyResult(outcome: failure, verified: nil)
        }
        let verified = VerifiedRoutingPolicy(bundle: bundle, delegateVerifiedZones: RoutingPolicyVerifier.delegateVerifiedZones(of: bundle))
        return PolicyResult(outcome: .valid, verified: verified)
    }

    /// The served policy must be the publicly logged one: a `POLICY_PUBLISH` leaf carries its content hash and
    /// the leaves recompute to the roster's checkpoint root.
    private func policyPublishFailure(contentHash: String, checkpoint: RosterLogCheckpoint, deadline: Date) async -> ResolverVerificationReport.Policy? {
        let log: TransparencyLogDocument
        do {
            let data = try await fetch("/roster/log", deadline: deadline)
            log = try JSONDecoder().decode(TransparencyLogDocument.self, from: data)
        } catch is DecodingError {
            return .unverifiable(reason: "parse_error")
        } catch {
            return .unverifiable(reason: (error as? FetchError)?.logReason ?? "log_unavailable")
        }
        let events = log.events.sorted { $0.index < $1.index }
        var leaves = [String]()
        for event in events {
            guard let recordedAt = ResolverInstant(iso: event.recordedAt) else { return .unverifiable(reason: "parse_error") }
            let data = MerkleTree.leafData(index: event.index, type: event.type, homeserverId: event.homeserverId,
                                           payloadHash: event.payloadHash, recordedAtEpochMilliseconds: recordedAt.epochMilliseconds)
            leaves.append(MerkleTree.leafHash(Array(data.utf8)))
        }
        guard checkpoint.size >= 0, checkpoint.size <= leaves.count,
              let root = MerkleTree.root(leafHashes: Array(leaves.prefix(Int(checkpoint.size)))), root == checkpoint.merkleRoot else {
            return .invalid(reason: "log_root_mismatch")
        }
        guard let published = events.firstIndex(where: { $0.type == "POLICY_PUBLISH" && $0.payloadHash == contentHash }) else {
            return .invalid(reason: "policy_not_logged")
        }
        // Only the leaves under the signed checkpoint are authenticated; a newer leaf waits for the next roster.
        return published < Int(checkpoint.size) ? nil : .unverifiable(reason: "policy_newer_than_checkpoint")
    }

    private func placement(resolution: HomeserverResolution, phoneNumber: String, roster: SignedRosterDocument,
                           policy: PolicyResult) async -> ResolverVerificationReport.Placement {
        // A directory hit cannot be reproduced: the phone graph is private and no inclusion proof is served.
        guard resolution.existsIsServed, !resolution.exists else { return .indeterminate }
        let verifiedPolicy: VerifiedRoutingPolicy?
        switch policy.outcome {
        case .notPresent: verifiedPolicy = nil
        case .valid: verifiedPolicy = policy.verified
        case .invalid, .unverifiable: return .unverifiable(reason: "policy_unverified")
        }
        let context = PlacementContext(phone: phoneNumber)
        guard let decision = PlacementReproducer.decide(context: context, roster: roster, policy: verifiedPolicy, nowEpochMilliseconds: clock()),
              let entry = roster.entries.first(where: { $0.homeserver.id == decision.homeserverId }) else {
            return .mismatch
        }
        let answer = resolution.homeserver
        let same = entry.homeserver.serverName == answer.serverName && entry.homeserver.baseUrl == answer.baseURL && entry.homeserver.masIssuer == answer.masIssuer
        return same ? .match : .mismatch
    }

    // MARK: - Transport

    private enum FetchError: Error, Equatable {
        case status(Int)
        case transport
        case timeout

        var rosterReason: String {
            self == .timeout ? "timeout" : "roster_unavailable"
        }

        var logReason: String {
            self == .timeout ? "timeout" : "log_unavailable"
        }

        var policyReason: String {
            self == .timeout ? "timeout" : "policy_unavailable"
        }
    }

    private func fetch(_ path: String, query: [URLQueryItem] = [], deadline: Date) async throws -> Data {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw FetchError.timeout }
        guard var components = URL(string: path, relativeTo: baseURL).flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: true) }) else {
            throw FetchError.transport
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw FetchError.transport }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = min(budget, remaining)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw FetchError.timeout
        } catch {
            throw FetchError.transport
        }
        guard let httpResponse = response as? HTTPURLResponse else { throw FetchError.transport }
        guard httpResponse.statusCode == 200 else { throw FetchError.status(httpResponse.statusCode) }
        return data
    }

    // MARK: - Draft

    /// The checks as they complete; whatever is left unset when a step stops early is `unverifiable`.
    private struct Draft {
        var rosterVersion: Int64?
        var rosterForm: String?
        var rosterSignature = ResolverVerificationReport.RosterSignature.unverifiable(reason: "roster_unavailable")
        var homeserverMatch = ResolverVerificationReport.HomeserverMatch.unverifiable
        var memberEntry = ResolverVerificationReport.MemberEntry.unverifiable
        var logConsistency = ResolverVerificationReport.LogConsistency.unverifiable(reason: "roster_unavailable")
        var policy = ResolverVerificationReport.Policy.unverifiable(reason: "roster_unavailable")
        var placement = ResolverVerificationReport.Placement.unverifiable(reason: "roster_unavailable")

        mutating func failEarly(_ signature: ResolverVerificationReport.RosterSignature, reason: String) {
            rosterSignature = signature
            logConsistency = .unverifiable(reason: reason)
            policy = .unverifiable(reason: reason)
            placement = .unverifiable(reason: reason)
        }

        func report(environment: String, durationMs: Int) -> ResolverVerificationReport {
            ResolverVerificationReport(environment: environment, rosterVersion: rosterVersion, rosterForm: rosterForm,
                                       rosterSignature: rosterSignature, homeserverMatch: homeserverMatch, memberEntry: memberEntry,
                                       logConsistency: logConsistency, policy: policy, placement: placement, durationMs: durationMs)
        }
    }
}
