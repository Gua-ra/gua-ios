//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import CryptoKit
import Foundation
import os

protocol ResolverVerifying: Sendable {
    /// Verifies a `/resolve` answer detached from the caller. The outcome is logged and never changes what the
    /// app connects to; the call returns at once and never throws.
    func startVerification(of resolution: HomeserverResolution, phoneNumber: String)
}

/// Report-only verification of the resolver's answer against its signed artifacts: the roster under the pinned
/// authority keys, the returned homeserver as an ACTIVE entry, the member self-signature, the log checkpoint
/// against the last one accepted, the routing policy when served, and the placement reproduced locally.
final class ResolverVerifier: ResolverVerifying {
    private let baseURL: URL
    private let trustRoots: ResolverTrustRoots
    private let environment: String
    private let isEnabled: @Sendable () -> Bool
    private let session: URLSession
    private let checkpointStore: ResolverCheckpointStoring
    private let budget: TimeInterval
    private let clock: @Sendable () -> Int64
    private let authorityKeys: [String: Curve25519.Signing.PublicKey]
    private let policyKeys: [String: Curve25519.Signing.PublicKey]

    private let latestReport = OSAllocatedUnfairLock<ResolverVerificationReport?>(initialState: nil)

    /// The most recent report, for tests and diagnostics.
    var lastReport: ResolverVerificationReport? {
        latestReport.withLock { $0 }
    }

    init(baseURL: URL,
         trustRoots: ResolverTrustRoots,
         environment: String,
         checkpointStore: ResolverCheckpointStoring = UserDefaultsResolverCheckpointStore(),
         session: URLSession? = nil,
         budget: TimeInterval = 10,
         clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
         isEnabled: @escaping @Sendable () -> Bool) {
        self.baseURL = baseURL
        self.trustRoots = trustRoots
        self.environment = environment
        self.isEnabled = isEnabled
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
        self.init(baseURL: baseURL, trustRoots: deployment.resolverTrustRoots, environment: deployment == .production ? "prod" : "dev") {
            appSettings.guaResolverVerificationEnabled
        }
    }

    func startVerification(of resolution: HomeserverResolution, phoneNumber: String) {
        guard isEnabled() else { return }
        Task.detached(priority: .utility) { [self] in
            _ = await verify(resolution: resolution, phoneNumber: phoneNumber)
        }
    }

    /// Runs every check and returns the report, or `nil` when the kill switch is off.
    func verify(resolution: HomeserverResolution, phoneNumber: String) async -> ResolverVerificationReport? {
        guard isEnabled() else { return nil }
        let started = Date()
        var draft = Draft()
        await run(resolution: resolution, phoneNumber: phoneNumber, deadline: started.addingTimeInterval(budget), draft: &draft)
        let report = draft.report(environment: environment, durationMs: Int(Date().timeIntervalSince(started) * 1000))
        latestReport.withLock { $0 = report }
        MXLog.info("Resolver verification \(report.logDescription)")
        return report
    }

    // MARK: - Checks

    private func run(resolution: HomeserverResolution, phoneNumber: String, deadline: Date, draft: inout Draft) async {
        guard trustRoots.hasAuthorityKeys else {
            draft.failEarly(unverifiable: "no_trust_roots")
            return
        }
        guard !authorityKeys.isEmpty else {
            draft.failEarly(unverifiable: "crypto_unsupported")
            return
        }

        let roster: SignedRosterDocument
        let malformedMembers: Set<Int>
        do {
            let data = try await fetch("/roster", deadline: deadline)
            guard let flagged = StrictJSONScanner.entriesWithDuplicateMemberKeys(in: data) else {
                draft.failEarly(unverifiable: "parse_error")
                return
            }
            malformedMembers = flagged
            roster = try JSONDecoder().decode(SignedRosterDocument.self, from: data)
        } catch let error as FetchError {
            draft.failEarly(unverifiable: error.reason(unavailable: "roster_unavailable"))
            return
        } catch {
            draft.failEarly(unverifiable: "parse_error")
            return
        }
        draft.rosterVersion = roster.version

        guard let form = CanonicalRoster.form(of: roster) else {
            draft.rosterForm = "mixed"
            draft.failEarly(unverifiable: "mixed_roster_form")
            return
        }
        draft.rosterForm = form.rawValue
        guard let canonical = CanonicalRoster.bytes(of: roster, form: form) else {
            draft.failEarly(unverifiable: "parse_error")
            return
        }

        let count = ResolverSignatureCounter.count(signatures: roster.authoritySignatures.map { ($0.authorityKeyId, $0.signatureB64) },
                                                   over: canonical, keys: authorityKeys)
        if let failure = count.failureReason(threshold: trustRoots.authorityThreshold) {
            draft.failEarly(invalid: failure)
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
        guard let index = roster.entries.firstIndex(where: { $0.homeserver.hasEndpoint(of: answer) }) else {
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
        guard let first = Int(exactly: pinned.size), let second = Int(exactly: served.size) else { return .unverifiable(reason: "parse_error") }
        let proof: ConsistencyProofDocument
        do {
            let data = try await fetch("/roster/log/consistency",
                                       query: [URLQueryItem(name: "first", value: String(first)), URLQueryItem(name: "second", value: String(second))],
                                       deadline: deadline)
            proof = try JSONDecoder().decode(ConsistencyProofDocument.self, from: data)
        } catch let error as FetchError {
            return .unverifiable(reason: error.reason(unavailable: "log_unavailable"))
        } catch {
            return .unverifiable(reason: "parse_error")
        }
        guard MerkleTree.verifyConsistency(first: first, second: second,
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
        } catch let error as FetchError {
            return PolicyResult(outcome: .unverifiable(reason: error.reason(unavailable: "policy_unavailable")), verified: nil)
        } catch {
            return PolicyResult(outcome: .unverifiable(reason: "parse_error"), verified: nil)
        }
        guard !trustRoots.policyKeys.isEmpty else { return PolicyResult(outcome: .unverifiable(reason: "no_policy_keys"), verified: nil) }
        guard !policyKeys.isEmpty else { return PolicyResult(outcome: .unverifiable(reason: "crypto_unsupported"), verified: nil) }
        guard let canonical = CanonicalRoutingPolicy.bytes(of: bundle) else {
            return PolicyResult(outcome: .unverifiable(reason: "parse_error"), verified: nil)
        }
        let count = RoutingPolicyVerifier.validSignatureCount(of: bundle, canonical: canonical, keys: policyKeys)
        if let failure = count.failureReason(threshold: trustRoots.policyThreshold) {
            return PolicyResult(outcome: .invalid(reason: failure), verified: nil)
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
        } catch let error as FetchError {
            return .unverifiable(reason: error.reason(unavailable: "log_unavailable"))
        } catch {
            return .unverifiable(reason: "parse_error")
        }
        let events = log.events.sorted { $0.index < $1.index }
        var leaves = [String]()
        for event in events {
            guard let recordedAt = ResolverInstant(iso: event.recordedAt) else { return .unverifiable(reason: "parse_error") }
            let data = MerkleTree.leafData(index: event.index, type: event.type, homeserverId: event.homeserverId,
                                           payloadHash: event.payloadHash, recordedAtEpochMilliseconds: recordedAt.epochMilliseconds)
            leaves.append(MerkleTree.leafHash(Array(data.utf8)))
        }
        guard let size = Int(exactly: checkpoint.size), size >= 0, size <= leaves.count,
              let root = MerkleTree.root(leafHashes: Array(leaves.prefix(size))), root == checkpoint.merkleRoot else {
            return .invalid(reason: "log_root_mismatch")
        }
        guard let published = events.firstIndex(where: { $0.type == "POLICY_PUBLISH" && $0.payloadHash == contentHash }) else {
            return .invalid(reason: "policy_not_logged")
        }
        // Only the leaves under the signed checkpoint are authenticated; a newer leaf waits for the next roster.
        return published < size ? nil : .unverifiable(reason: "policy_newer_than_checkpoint")
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
        return entry.homeserver.hasEndpoint(of: resolution.homeserver) ? .match : .mismatch
    }

    // MARK: - Transport

    private enum FetchError: Error, Equatable {
        case status(Int)
        case transport
        case timeout

        func reason(unavailable: String) -> String {
            self == .timeout ? "timeout" : unavailable
        }
    }

    /// Each fetch is bounded by the time left in the budget, so one slow response cannot stretch the run past it.
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
        request.timeoutInterval = remaining
        let data: Data
        let status: Int
        do {
            (data, status) = try await withThrowingTaskGroup(of: (Data, Int).self) { [session, request] group in
                group.addTask {
                    let (body, response) = try await session.data(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                    return (body, httpResponse.statusCode)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(remaining))
                    throw URLError(.timedOut)
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw URLError(.unknown) }
                return first
            }
        } catch let error as URLError where error.code == .timedOut {
            throw FetchError.timeout
        } catch {
            throw FetchError.transport
        }
        guard status == 200 else { throw FetchError.status(status) }
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

        /// The roster could not be checked: the checks that depend on it carry the same reason.
        mutating func failEarly(unverifiable reason: String) {
            rosterSignature = .unverifiable(reason: reason)
            settleDependentChecks(reason)
        }

        /// The roster's signatures fell short: the checks that depend on it are `roster_unverified`.
        mutating func failEarly(invalid reason: String) {
            rosterSignature = .invalid(reason: reason)
            settleDependentChecks("roster_unverified")
        }

        private mutating func settleDependentChecks(_ reason: String) {
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
