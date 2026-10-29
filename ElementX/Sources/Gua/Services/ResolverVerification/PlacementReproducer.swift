//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// What the placement rules may use to decide where a new account lives. The app knows the phone only;
/// `claimsVerified` stays false because a public caller never carries a verified routing-claims envelope.
struct PlacementContext: Equatable {
    var phone: String?
    var country: String?
    var mccmnc: String?
    var carrier: String?
    var regionHint: String?
    var affiliations: [String] = []
    var attributes: [String: String] = [:]
    var claimsVerified = false

    /// The weighted fallback's bucketing key. A plain distribution key, not a signed form.
    var canonicalRoutingKey: String {
        var text = "phone=\(phone ?? "")\n"
        text += "country=\(country ?? "")\n"
        text += "mccmnc=\(mccmnc ?? "")\n"
        text += "carrier=\(carrier ?? "")\n"
        text += "region=\(regionHint ?? "")\n"
        text += "affiliations=\(JavaStringOrder.sorted(affiliations).joined(separator: "|"))\n"
        text += "attrs="
        for (key, value) in attributes.sorted(by: { JavaStringOrder.precedes($0.key, $1.key) }) {
            text += "\(key)=\(value)|"
        }
        return text
    }
}

struct PlacementDecision: Equatable {
    let homeserverId: String
    let rule: String
    let ruleId: String
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

    // MARK: - Policy rule

    private static func policyRule(context: PlacementContext, roster: SignedRosterDocument, policy: VerifiedRoutingPolicy,
                                   now: Int64) -> PlacementDecision? {
        let targets = Dictionary(roster.activeEntries.map(\.homeserver).filter(\.acceptsNew).map { ($0.id, $0) }) { first, _ in first }
        var zones = [String: DelegationZone]()
        for zone in policy.bundle.delegationZones {
            if let id = zone.id, zones[id] == nil { zones[id] = zone }
        }
        let rules = policy.bundle.rules.filter { rule in
            guard rule.isEnabled, let zoneId = rule.delegatedZoneId, policy.delegateVerifiedZones.contains(zoneId) else { return false }
            return zoneIsActive(zones[zoneId], now: now)
        }
        for rule in CanonicalRoutingPolicy.sortedRules(rules) where matches(rule, context: context) {
            if let targetId = rule.targetHomeserverId, targets[targetId] != nil {
                return PlacementDecision(homeserverId: targetId, rule: "PolicyRoutingRule", ruleId: rule.id ?? "")
            }
        }
        return nil
    }

    private static func zoneIsActive(_ zone: DelegationZone?, now: Int64) -> Bool {
        guard let zone else { return false }
        if let notBefore = zone.notBefore {
            guard let start = ResolverInstant(iso: notBefore)?.epochMilliseconds, start <= now else { return false }
        }
        guard let expiresAt = zone.expiresAt else { return true }
        guard let end = ResolverInstant(iso: expiresAt)?.epochMilliseconds else { return false }
        return end > now
    }

    private static func matches(_ rule: RoutingPolicyRule, context: PlacementContext) -> Bool {
        switch rule.matchType {
        case "PHONE_PREFIX":
            guard let phone = context.phone, let prefix = rule.matchValue else { return false }
            return phone.hasPrefix(prefix)
        case "INSTITUTION_DOMAIN":
            return context.claimsVerified && domainMatches(rule.matchValue, context: context)
        case "OIDC_CLAIM":
            return context.claimsVerified && oidcClaimMatches(rule, context: context)
        default:
            return false
        }
    }

    private static func domainMatches(_ domain: String?, context: PlacementContext) -> Bool {
        let normalized = normalize(domain)
        if context.affiliations.map(normalize).contains(where: { $0 == normalized || $0.hasSuffix("." + normalized) }) {
            return true
        }
        return ["email_domain", "hd", "institution_domain"].contains { normalized == normalize(context.attributes[$0]) }
    }

    private static func oidcClaimMatches(_ rule: RoutingPolicyRule, context: PlacementContext) -> Bool {
        if let issuer = rule.oidcIssuer, !issuer.trimmingCharacters(in: .whitespaces).isEmpty {
            let contextIssuer = context.attributes["oidc_issuer"] ?? context.attributes["iss"] ?? ""
            guard issuer.lowercased() == contextIssuer.lowercased() else { return false }
        }
        guard let claim = rule.oidcClaim, !claim.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return normalize(rule.matchValue) == normalize(context.attributes[claim])
    }

    private static func normalize(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Roster claim

    private static func claimRule(context: PlacementContext, roster: SignedRosterDocument) -> PlacementDecision? {
        var best: (priority: Int, homeserverId: String)?
        for entry in roster.activeEntries where entry.homeserver.acceptsNew {
            for claim in entry.claims where !claim.isRemote && matchesLocally(claim, context: context) {
                let candidate = (priority: claim.priority, homeserverId: entry.homeserver.id)
                if let current = best {
                    if candidate.priority < current.priority
                        || (candidate.priority == current.priority && JavaStringOrder.precedes(candidate.homeserverId, current.homeserverId)) {
                        best = candidate
                    }
                } else {
                    best = candidate
                }
            }
        }
        guard let best else { return nil }
        return PlacementDecision(homeserverId: best.homeserverId, rule: "ClaimRule",
                                 ruleId: "roster-claim:\(best.homeserverId):\(best.priority)")
    }

    private static func matchesLocally(_ claim: RosterClaimPredicate, context: PlacementContext) -> Bool {
        if let country = claim.country, country.lowercased() != context.country?.lowercased() { return false }
        if let mccmnc = claim.mccmnc, mccmnc != context.mccmnc { return false }
        if let carrier = claim.carrier, carrier.lowercased() != context.carrier?.lowercased() { return false }
        if let prefixes = claim.phonePrefixes, !prefixes.isEmpty, !prefixes.contains(where: { context.phone?.hasPrefix($0) == true }) {
            return false
        }
        if let affiliation = claim.affiliation, !(context.claimsVerified && context.affiliations.contains(affiliation)) { return false }
        if let attributes = claim.attributeMatch, !attributes.isEmpty,
           !(context.claimsVerified && attributes.allSatisfy { context.attributes[$0.key] == $0.value }) {
            return false
        }
        return true
    }

    // MARK: - Weighted fallback

    static func fallbackCandidates(in roster: SignedRosterDocument) -> [RosterHomeserver] {
        roster.activeEntries.map(\.homeserver).filter(\.acceptsNew)
            .stableSorted { JavaStringOrder.compare($0.id, $1.id) }
    }

    private static func weightedFallback(context: PlacementContext, roster: SignedRosterDocument) -> PlacementDecision? {
        let candidates = fallbackCandidates(in: roster)
        guard !candidates.isEmpty else { return nil }
        let hash = stableHash(context: context, rosterVersion: roster.version, candidates: candidates)
        let totalWeight = candidates.reduce(0) { $0 + max(0, $1.weight) }
        let chosen: RosterHomeserver
        if totalWeight <= 0 {
            chosen = candidates[floorMod(hash, candidates.count)]
        } else {
            let target = floorMod(hash, totalWeight)
            var cumulative = 0
            var picked = candidates[candidates.count - 1]
            for candidate in candidates {
                cumulative += max(0, candidate.weight)
                if target < cumulative {
                    picked = candidate
                    break
                }
            }
            chosen = picked
        }
        return PlacementDecision(homeserverId: chosen.id, rule: "WeightedFallbackRule", ruleId: "weighted-fallback")
    }

    /// The first four bytes of SHA-256 over the roster version, the routing key and the candidates, as a
    /// signed 32-bit integer.
    static func stableHash(context: PlacementContext, rosterVersion: Int64, candidates: [RosterHomeserver]) -> Int32 {
        var message = Array("weighted-fallback.v1\nroster=\(rosterVersion)\n".utf8)
        message += Array(context.canonicalRoutingKey.utf8)
        for candidate in candidates {
            message += Array("\n\(candidate.id):\(max(0, candidate.weight))".utf8)
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
