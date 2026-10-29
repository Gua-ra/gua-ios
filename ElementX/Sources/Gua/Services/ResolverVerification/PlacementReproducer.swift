//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// What the placement rules see of a new account. A public caller carries no verified routing claims, so its
/// affiliations and attributes never match a rule and are left out of the fallback's key, as the server does.
struct PlacementContext: Equatable {
    var phone: String?
    var country: String?
    var mccmnc: String?
    var carrier: String?
    var regionHint: String?

    /// The weighted fallback's bucketing key. A plain distribution key, not a signed form.
    var canonicalRoutingKey: String {
        "phone=\(phone ?? "")\ncountry=\(country ?? "")\nmccmnc=\(mccmnc ?? "")\ncarrier=\(carrier ?? "")\nregion=\(regionHint ?? "")\naffiliations=\nattrs="
    }
}

struct PlacementDecision {
    enum Rule {
        case policy(RoutingPolicyRule)
        case rosterClaim(priority: Int32)
        case weightedFallback
    }

    let homeserver: RosterHomeserver
    let rule: Rule
}

/// A policy bundle whose authority signatures verified, with the zones whose delegate signatures did too.
struct VerifiedRoutingPolicy {
    let bundle: RoutingPolicyBundle
    let delegateVerifiedZones: Set<String>
}

/// The resolver's placement pipeline over verified artifacts: signed policy rules, then roster claims, then
/// the stable weighted fallback. The first rule that yields a homeserver decides.
enum PlacementReproducer {
    static func decide(context: PlacementContext, roster: SignedRosterDocument, policy: VerifiedRoutingPolicy?,
                       nowEpochMilliseconds now: Int64) -> PlacementDecision? {
        if let policy, let decision = policyRule(context: context, roster: roster, policy: policy, now: now) {
            return decision
        }
        if let decision = claimRule(context: context, roster: roster) {
            return decision
        }
        return weightedFallback(context: context, roster: roster)
    }

    /// Whether a rule that lacks only a valid delegate signature outranks the rule that decided. Delegate signatures
    /// are outside the bundle signatures and its log leaf, so a resolver can strip one to hide a rule.
    static func unsignedRuleRanksAbove(_ decision: PlacementDecision?, context: PlacementContext, policy: VerifiedRoutingPolicy,
                                       nowEpochMilliseconds now: Int64) -> Bool {
        guard let unsigned = phoneRules(of: policy, context: context, now: now, delegateSigned: false).first else { return false }
        guard case .policy(let decided) = decision?.rule else { return true }
        return CanonicalRoutingPolicy.compareRules(unsigned, decided) < 0
    }

    // MARK: - Policy rule

    private static func policyRule(context: PlacementContext, roster: SignedRosterDocument, policy: VerifiedRoutingPolicy,
                                   now: Int64) -> PlacementDecision? {
        let candidates = roster.activeEntries.map(\.homeserver).filter(\.acceptsNew)
        let targets = Dictionary(candidates.compactMap { homeserver in homeserver.id.map { ($0, homeserver) } }) { first, _ in first }
        for rule in phoneRules(of: policy, context: context, now: now, delegateSigned: true) {
            if let targetId = rule.targetHomeserverId, let target = targets[targetId] {
                return PlacementDecision(homeserver: target, rule: .policy(rule))
            }
        }
        return nil
    }

    /// The enabled phone prefix rules that match, in rank order, whose zone is in effect and does or does not
    /// carry a valid delegate signature. No other match type can hold without verified claims.
    private static func phoneRules(of policy: VerifiedRoutingPolicy, context: PlacementContext, now: Int64,
                                   delegateSigned: Bool) -> [RoutingPolicyRule] {
        var zones = [String: DelegationZone]()
        for zone in policy.bundle.delegationZones {
            if let id = zone.id, zones[id] == nil { zones[id] = zone }
        }
        let rules = policy.bundle.rules.filter { rule in
            guard rule.isEnabled, rule.matchType == "PHONE_PREFIX", let prefix = rule.matchValue, context.phone?.hasPrefix(prefix) == true,
                  let zoneId = rule.delegatedZoneId, zones[zoneId]?.isInEffect(atEpochMilliseconds: now) == true else {
                return false
            }
            return policy.delegateVerifiedZones.contains(zoneId) == delegateSigned
        }
        return CanonicalRoutingPolicy.sortedRules(rules)
    }

    // MARK: - Roster claim

    private static func claimRule(context: PlacementContext, roster: SignedRosterDocument) -> PlacementDecision? {
        var best: (priority: Int32, homeserver: RosterHomeserver)?
        for entry in roster.activeEntries where entry.homeserver.acceptsNew {
            for claim in entry.claims where !claim.isRemote && matchesLocally(claim, context: context) {
                let isBetter = best.map { current in
                    claim.priority < current.priority
                        || (claim.priority == current.priority && JavaStringOrder.compare(entry.homeserver.id, current.homeserver.id) < 0)
                } ?? true
                if isBetter { best = (claim.priority, entry.homeserver) }
            }
        }
        return best.map { PlacementDecision(homeserver: $0.homeserver, rule: .rosterClaim(priority: $0.priority)) }
    }

    /// Affiliation and attribute predicates need verified claims, so a claim that names either never matches.
    private static func matchesLocally(_ claim: RosterClaimPredicate, context: PlacementContext) -> Bool {
        if claim.affiliation != nil || claim.attributeMatch?.isEmpty == false { return false }
        if let country = claim.country, country.lowercased() != context.country?.lowercased() { return false }
        if let mccmnc = claim.mccmnc, mccmnc != context.mccmnc { return false }
        if let carrier = claim.carrier, carrier.lowercased() != context.carrier?.lowercased() { return false }
        guard let prefixes = claim.phonePrefixes, !prefixes.isEmpty else { return true }
        return prefixes.contains { context.phone?.hasPrefix($0) == true }
    }

    // MARK: - Weighted fallback

    static func fallbackCandidates(in roster: SignedRosterDocument) -> [RosterHomeserver] {
        roster.activeEntries.map(\.homeserver).filter(\.acceptsNew)
            .sorted { JavaStringOrder.compare($0.id, $1.id) < 0 }
    }

    private static func weightedFallback(context: PlacementContext, roster: SignedRosterDocument) -> PlacementDecision? {
        let candidates = fallbackCandidates(in: roster)
        guard !candidates.isEmpty else { return nil }
        let hash = stableHash(context: context, rosterVersion: roster.version, candidates: candidates)
        return PlacementDecision(homeserver: pick(from: candidates, hash: hash), rule: .weightedFallback)
    }

    private static func pick(from candidates: [RosterHomeserver], hash: Int32) -> RosterHomeserver {
        // Summed in 64 bits, so int32 weights whose total passes 2^31 do not wrap.
        let totalWeight = candidates.reduce(0) { $0 + Int(max(0, $1.weight)) }
        guard totalWeight > 0 else { return candidates[floorMod(hash, candidates.count)] }
        let target = floorMod(hash, totalWeight)
        var cumulative = 0
        for candidate in candidates {
            cumulative += Int(max(0, candidate.weight))
            if target < cumulative { return candidate }
        }
        return candidates[candidates.count - 1]
    }

    /// The first four bytes of SHA-256 over the roster version, the routing key and the candidates, as a
    /// signed 32-bit integer.
    static func stableHash(context: PlacementContext, rosterVersion: Int64, candidates: [RosterHomeserver]) -> Int32 {
        var message = Array("weighted-fallback.v1\nroster=\(rosterVersion)\n".utf8)
        message += Array(context.canonicalRoutingKey.utf8)
        for candidate in candidates {
            message += Array("\n\(candidate.id ?? "null"):\(max(0, candidate.weight))".utf8)
        }
        let digest = ResolverVerificationCrypto.sha256(message)
        let value = UInt32(digest[0]) << 24 | UInt32(digest[1]) << 16 | UInt32(digest[2]) << 8 | UInt32(digest[3])
        return Int32(bitPattern: value)
    }

    /// Java's `Math.floorMod`: the result takes the sign of the divisor.
    private static func floorMod(_ value: Int32, _ modulus: Int) -> Int {
        let remainder = Int(value) % modulus
        return remainder < 0 ? remainder + modulus : remainder
    }
}
