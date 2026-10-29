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

/// Report-only verification of a resolver answer: the signed roster, the answer's entry and its member signature,
/// the log checkpoint against the last one accepted, the routing policy, and the placement reproduced locally.
final class ResolverVerifier: ResolverVerifying {
    typealias Report = ResolverVerificationReport
    typealias Reason = ResolverVerificationReason

    /// The largest checkpoint whose log is fetched to bind the policy to it.
    static let maxLogSize = 4096

    private let baseURL: URL
    private let environment: String
    private let authorityKeys: [String: Curve25519.Signing.PublicKey]
    private let authorityThreshold: Int
    private let policyKeys: [String: Curve25519.Signing.PublicKey]
    private let policyThreshold: Int
    private let checkpointStore: ResolverCheckpointStoring
    private let fetcher: ResolverDocumentFetcher
    private let budget: Duration
    private let now: @Sendable () -> Int64
    private let isEnabled: @Sendable () -> Bool
    private let latestReport = OSAllocatedUnfairLock<Report?>(initialState: nil)

    /// The most recent report, for tests and diagnostics.
    var lastReport: Report? {
        latestReport.withLock { $0 }
    }

    /// `now` is the wall clock in epoch milliseconds, for validity windows; the budget runs on a monotonic clock.
    init(baseURL: URL,
         trustRoots: ResolverTrustRoots,
         environment: String,
         checkpointStore: ResolverCheckpointStoring = UserDefaultsResolverCheckpointStore(),
         session: URLSession? = nil,
         budget: Duration = .seconds(10),
         now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
         isEnabled: @escaping @Sendable () -> Bool) {
        self.baseURL = baseURL
        self.environment = environment
        authorityKeys = ResolverSignatureCounter.keys(trustRoots.authorityKeys)
        authorityThreshold = trustRoots.authorityThreshold
        policyKeys = ResolverSignatureCounter.keys(trustRoots.policyKeys)
        policyThreshold = trustRoots.policyThreshold
        self.checkpointStore = checkpointStore
        self.budget = budget
        self.now = now
        self.isEnabled = isEnabled
        if let session {
            fetcher = ResolverDocumentFetcher(baseURL: baseURL, session: session)
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = budget / .seconds(1)
            configuration.timeoutIntervalForResource = budget / .seconds(1)
            fetcher = ResolverDocumentFetcher(baseURL: baseURL, session: URLSession(configuration: configuration))
        }
    }

    /// `nil` when the deployment has no resolver.
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
    func verify(resolution: HomeserverResolution, phoneNumber: String) async -> Report? {
        guard isEnabled() else { return nil }
        let report = await ResolverRunQueue.shared.run(for: baseURL) { [self] in
            await run(resolution, phoneNumber: phoneNumber)
        }
        latestReport.withLock { $0 = report }
        MXLog.info("Resolver verification \(report.logDescription)")
        return report
    }

    private func run(_ resolution: HomeserverResolution, phoneNumber: String) async -> Report {
        let started = ContinuousClock.now
        let deadline = started + budget
        let roster: VerifiedRoster
        do {
            roster = try await verifyRoster(deadline: deadline)
        } catch {
            return report(stoppedAt: error, started: started)
        }
        let checkpoint = roster.document.logCheckpoint
        let logConsistency = await checkLogConsistency(of: checkpoint, deadline: deadline)
        let policy = await checkPolicy(under: checkpoint, deadline: deadline)
        let located = Self.locate(resolution.homeserver, in: roster.document)
        return Report(environment: environment, rosterVersion: roster.document.version, rosterForm: roster.form.rawValue,
                      rosterSignature: .valid, homeserverMatch: located.match, memberEntry: checkMember(of: located),
                      logConsistency: logConsistency, policy: policy.outcome,
                      placement: checkPlacement(of: resolution, phoneNumber: phoneNumber, roster: roster.document, policy: policy),
                      durationMs: Self.milliseconds(since: started))
    }

    // MARK: - Roster

    private struct VerifiedRoster {
        let document: SignedRosterDocument
        let form: RosterForm
    }

    /// Why a run stopped at the roster. An invalid roster leaves the other checks `roster_unverified`; an
    /// unverifiable one passes its own reason on.
    private struct RosterStop: Error {
        let rosterSignature: Report.RosterSignature
        let dependentReason: Reason
        let rosterForm: String?

        static func unverifiable(_ reason: Reason, rosterForm: String? = nil) -> RosterStop {
            RosterStop(rosterSignature: .unverifiable(reason), dependentReason: reason, rosterForm: rosterForm)
        }

        static func invalid(_ reason: Reason, rosterForm: RosterForm) -> RosterStop {
            RosterStop(rosterSignature: .invalid(reason), dependentReason: .rosterUnverified, rosterForm: rosterForm.rawValue)
        }
    }

    private func verifyRoster(deadline: ContinuousClock.Instant) async throws(RosterStop) -> VerifiedRoster {
        guard !authorityKeys.isEmpty else { throw .unverifiable(.noTrustRoots) }
        let roster = try await loadRoster(deadline: deadline)
        guard let form = CanonicalRoster.form(of: roster) else { throw .unverifiable(.mixedRosterForm, rosterForm: "mixed") }
        guard let canonical = CanonicalRoster.bytes(of: roster, form: form) else {
            throw .unverifiable(.parseError, rosterForm: form.rawValue)
        }
        let count = ResolverSignatureCounter.count(signatures: roster.authoritySignatures.map { ($0.authorityKeyId, $0.signatureB64) },
                                                   over: canonical, keys: authorityKeys)
        if let failure = count.failureReason(threshold: authorityThreshold) { throw .invalid(failure, rosterForm: form) }
        return VerifiedRoster(document: roster, form: form)
    }

    private func loadRoster(deadline: ContinuousClock.Instant) async throws(RosterStop) -> SignedRosterDocument {
        do {
            return try await fetcher.document(SignedRosterDocument.self, at: "/roster", deadline: deadline)
        } catch {
            throw .unverifiable(error.reason(unavailable: .rosterUnavailable))
        }
    }

    private func report(stoppedAt stop: RosterStop, started: ContinuousClock.Instant) -> Report {
        let reason = stop.dependentReason
        return Report(environment: environment, rosterVersion: nil, rosterForm: stop.rosterForm, rosterSignature: stop.rosterSignature,
                      homeserverMatch: .unverifiable(reason), memberEntry: .unverifiable(reason), logConsistency: .unverifiable(reason),
                      policy: .unverifiable(reason), placement: .unverifiable(reason), durationMs: Self.milliseconds(since: started))
    }

    // MARK: - Answer in the roster

    /// Where an answer sits in the roster: the strongest match wins whatever the entry order, and a tie goes to the
    /// entry served first. Only an ACTIVE entry with all three fields of the answer may be connected to.
    static func locate(_ answer: ResolvedHomeserver, in roster: SignedRosterDocument) -> (match: Report.HomeserverMatch, entry: SignedRosterEntry?) {
        let named = roster.entries.filter { $0.homeserver.serverName == answer.serverName }
        let sameEndpoint = named.filter { $0.homeserver.hasEndpoint(of: answer) }
        if let entry = sameEndpoint.first(where: \.isActive) { return (.activeMatch, entry) }
        if let entry = sameEndpoint.first { return (.inactive, entry) }
        if let entry = named.first { return (.fieldMismatch, entry) }
        return (.notInRoster, nil)
    }

    private func checkMember(of located: (match: Report.HomeserverMatch, entry: SignedRosterEntry?)) -> Report.MemberEntry {
        guard let entry = located.entry, located.match == .activeMatch || located.match == .inactive else {
            return .unverifiable(.noMatchingEntry)
        }
        if entry.memberIsMalformed { return .invalid(.parseError) }
        return MemberEntryVerifier.verify(homeserver: entry.homeserver, member: entry.member, atEpochMilliseconds: now())
    }

    // MARK: - Log

    private func checkLogConsistency(of served: RosterLogCheckpoint, deadline: ContinuousClock.Instant) async -> Report.LogConsistency {
        let pinned: RosterLogCheckpoint?
        do {
            pinned = try checkpointStore.checkpoint(for: baseURL)
        } catch {
            return .unverifiable(.storageUnavailable)
        }
        guard let pinned, pinned.size > 0 else { return pin(served, as: .firstSeen) }
        if served.size < pinned.size { return .rollback }
        if served.size == pinned.size { return served.merkleRoot == pinned.merkleRoot ? .consistent : .inconsistent }
        let proof: ConsistencyProofDocument
        do {
            let query = [URLQueryItem(name: "first", value: String(pinned.size)), URLQueryItem(name: "second", value: String(served.size))]
            proof = try await fetcher.document(ConsistencyProofDocument.self, at: "/roster/log/consistency", query: query, deadline: deadline)
        } catch {
            return .unverifiable(error.reason(unavailable: .logUnavailable))
        }
        guard MerkleTree.verifyConsistency(first: pinned.size, second: served.size, oldRoot: pinned.merkleRoot,
                                           newRoot: served.merkleRoot, proof: proof.proof) else {
            return .inconsistent
        }
        return pin(served, as: .consistent)
    }

    private func pin(_ checkpoint: RosterLogCheckpoint, as outcome: Report.LogConsistency) -> Report.LogConsistency {
        do {
            try checkpointStore.store(checkpoint, for: baseURL)
            return outcome
        } catch {
            return .unverifiable(.storageUnavailable)
        }
    }

    // MARK: - Policy

    private enum PolicyStage {
        case notPresent
        case verified(VerifiedRoutingPolicy)
        case failed(Report.Policy)

        var outcome: Report.Policy {
            switch self {
            case .notPresent: .notPresent
            case .verified: .valid
            case .failed(let outcome): outcome
            }
        }
    }

    private struct PolicyFailure: Error {
        let outcome: Report.Policy

        static func invalid(_ reason: Reason) -> PolicyFailure {
            PolicyFailure(outcome: .invalid(reason))
        }

        static func unverifiable(_ reason: Reason) -> PolicyFailure {
            PolicyFailure(outcome: .unverifiable(reason))
        }
    }

    private func checkPolicy(under checkpoint: RosterLogCheckpoint, deadline: ContinuousClock.Instant) async -> PolicyStage {
        do {
            return try await verifyPolicy(under: checkpoint, deadline: deadline)
        } catch {
            return .failed(error.outcome)
        }
    }

    private func verifyPolicy(under checkpoint: RosterLogCheckpoint, deadline: ContinuousClock.Instant) async throws(PolicyFailure) -> PolicyStage {
        let bundle: RoutingPolicyBundle?
        do {
            bundle = try await fetcher.document(RoutingPolicyBundle.self, at: "/policy/routing", deadline: deadline)
        } catch .status(404) {
            bundle = nil
        } catch {
            throw .unverifiable(error.reason(unavailable: .policyUnavailable))
        }
        var served: ServedPolicy?
        if let bundle {
            served = try ServedPolicy(policyId: bundle.policyId, version: bundle.version,
                                      contentHash: ResolverVerificationCrypto.sha256Hex(verifiedBytes(of: bundle)))
        }
        let outcome = try await Self.logOutcome(for: served, checkpoint: checkpoint, events: fetchLog(under: checkpoint, deadline: deadline))
        if outcome == .notPresent { return .notPresent }
        guard outcome == .valid, let bundle else { throw PolicyFailure(outcome: outcome) }
        return .verified(VerifiedRoutingPolicy(bundle: bundle, delegateVerifiedZones: RoutingPolicyVerifier.delegateVerifiedZones(of: bundle)))
    }

    /// The canonical bytes of a bundle signed by enough policy keys and in effect now.
    private func verifiedBytes(of bundle: RoutingPolicyBundle) throws(PolicyFailure) -> [UInt8] {
        guard !policyKeys.isEmpty else { throw .unverifiable(.noPolicyKeys) }
        guard let canonical = CanonicalRoutingPolicy.bytes(of: bundle) else { throw .unverifiable(.parseError) }
        let count = RoutingPolicyVerifier.validSignatureCount(of: bundle, canonical: canonical, keys: policyKeys)
        if let failure = count.failureReason(threshold: policyThreshold) { throw .invalid(failure) }
        guard bundle.isInEffect(atEpochMilliseconds: now()) else { throw .invalid(.outsideWindow) }
        return canonical
    }

    private func fetchLog(under checkpoint: RosterLogCheckpoint, deadline: ContinuousClock.Instant) async throws(PolicyFailure) -> [TransparencyLogEvent] {
        guard checkpoint.size <= Self.maxLogSize else { throw .unverifiable(.logTooLarge) }
        do {
            return try await fetcher.document(TransparencyLogDocument.self, at: "/roster/log", deadline: deadline).events
        } catch {
            throw .unverifiable(error.reason(unavailable: .logUnavailable))
        }
    }

    /// The policy outcome of the log: the checkpoint's leaves must hash to its signed root, and the served bundle,
    /// `nil` for a 404, must be the latest policy published under it.
    static func logOutcome(for served: ServedPolicy?, checkpoint: RosterLogCheckpoint, events: [TransparencyLogEvent]) -> Report.Policy {
        var leaves = [String]()
        for event in events {
            guard let recordedAt = ResolverInstant(iso: event.recordedAt) else { return .unverifiable(.parseError) }
            let data = MerkleTree.leafData(index: event.index, type: event.type, homeserverId: event.homeserverId,
                                           payloadHash: event.payloadHash, recordedAtEpochMilliseconds: recordedAt.epochMilliseconds)
            leaves.append(MerkleTree.leafHash(Array(data.utf8)))
        }
        guard (0...leaves.count).contains(checkpoint.size),
              MerkleTree.root(leafHashes: Array(leaves.prefix(checkpoint.size))) == checkpoint.merkleRoot else {
            return .invalid(.logMismatch)
        }
        let signed = events.prefix(checkpoint.size)
        guard let served else {
            // A resolver that withholds a published policy must not pass for one that never had one.
            return signed.contains(where: \.isPolicyPublication) ? .unverifiable(.policyNotServed) : .notPresent
        }
        guard let published = events.firstIndex(where: { $0.isPolicyPublication && $0.payloadHash == served.contentHash }) else {
            return .invalid(.policyNotLogged)
        }
        if signed.contains(where: { $0.publishesLaterVersion(of: served) }) { return .unverifiable(.policySuperseded) }
        // Only leaves under the signed checkpoint are authenticated; an honest publish waits for the next roster.
        return published < checkpoint.size ? .valid : .unverifiable(.policyNewerThanCheckpoint)
    }

    // MARK: - Placement

    private func checkPlacement(of resolution: HomeserverResolution, phoneNumber: String, roster: SignedRosterDocument,
                                policy: PolicyStage) -> Report.Placement {
        // A directory lookup cannot be reproduced: the phone graph is private and no inclusion proof is served.
        guard resolution.existsIsServed, !resolution.exists else { return .indeterminate(.existingAccount) }
        let verifiedPolicy: VerifiedRoutingPolicy?
        switch policy {
        case .notPresent: verifiedPolicy = nil
        case .verified(let verified): verifiedPolicy = verified
        case .failed: return .unverifiable(.policyUnverified)
        }
        let context = PlacementContext(phone: phoneNumber)
        let evaluatedAt = now()
        let decision = PlacementReproducer.decide(context: context, roster: roster, policy: verifiedPolicy, nowEpochMilliseconds: evaluatedAt)
        if let verifiedPolicy,
           PlacementReproducer.unsignedRuleRanksAbove(decision, context: context, policy: verifiedPolicy, nowEpochMilliseconds: evaluatedAt) {
            return .indeterminate(.unsignedRule)
        }
        guard let decision else { return .indeterminate(.unattributed) }
        if decision.homeserver.hasEndpoint(of: resolution.homeserver) { return .match }
        // The resolver may have decided against another roster, so only the same version makes a difference a misroute.
        return resolution.rosterVersion == roster.version ? .mismatch : .indeterminate(.unattributed)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        Int((ContinuousClock.now - start) / .milliseconds(1))
    }
}

/// Runs against one resolver base URL take turns across every verifier in the process, so a run reads and writes
/// the pin with no other run in between and the pin only moves forward.
private actor ResolverRunQueue {
    static let shared = ResolverRunQueue()

    private var lastRuns = [URL: Task<ResolverVerificationReport, Never>]()

    func run(for baseURL: URL, _ operation: @escaping @Sendable () async -> ResolverVerificationReport) async -> ResolverVerificationReport {
        let previous = lastRuns[baseURL]
        let run = Task {
            _ = await previous?.value
            return await operation()
        }
        lastRuns[baseURL] = run
        return await run.value
    }
}
