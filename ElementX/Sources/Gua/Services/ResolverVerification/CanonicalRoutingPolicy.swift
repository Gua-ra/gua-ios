//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// Ports of the resolver's `CanonicalRoutingPolicy` and `CanonicalDelegatedRules`.
enum CanonicalRoutingPolicy {
    private static let separator = "\u{1F}"

    static func bytes(of bundle: RoutingPolicyBundle) -> [UInt8]? {
        guard let issuedAt = epoch(bundle.issuedAt), let notBefore = epoch(bundle.notBefore), let expiresAt = epoch(bundle.expiresAt) else {
            return nil
        }
        var text = "gua-routing-policy.v1\n"
        text += "schema=\(bundle.schemaVersion ?? "")\n"
        text += "policyId=\(bundle.policyId ?? "")\n"
        text += "version=\(bundle.version)\n"
        text += "issuedAt=\(issuedAt)\n"
        text += "notBefore=\(notBefore)\n"
        text += "expiresAt=\(expiresAt)\n"
        for zone in bundle.delegationZones.sorted(by: { JavaStringOrder.compare($0.id, $1.id) < 0 }) {
            guard let line = zoneLine(zone) else { return nil }
            text += line + "\n"
        }
        for rule in sortedRules(bundle.rules) {
            text += ruleLine(rule) + "\n"
        }
        let fallback = bundle.fallback.map { "\($0.type ?? ""):\($0.enabled ? "true" : "false")" } ?? ""
        text += "fallback=\(fallback)\n"
        return Array(text.utf8)
    }

    static func delegatedRulesBytes(policyId: String?, version: Int64, zoneId: String, rules: [RoutingPolicyRule]) -> [UInt8] {
        var text = "gua-delegated-rules.v1\n"
        text += "policyId=\(policyId ?? "")\n"
        text += "version=\(version)\n"
        text += "zoneId=\(zoneId)\n"
        for rule in sortedRules(rules) where rule.delegatedZoneId == zoneId {
            text += ruleLine(rule) + "\n"
        }
        return Array(text.utf8)
    }

    static func sortedRules(_ rules: [RoutingPolicyRule]) -> [RoutingPolicyRule] {
        rules.sorted { compareRules($0, $1) < 0 }
    }

    static func compareRules(_ lhs: RoutingPolicyRule, _ rhs: RoutingPolicyRule) -> Int {
        if lhs.priority != rhs.priority { return lhs.priority < rhs.priority ? -1 : 1 }
        return JavaStringOrder.compare(lhs.id, rhs.id)
    }

    private static func zoneLine(_ zone: DelegationZone) -> String? {
        guard let notBefore = epoch(zone.notBefore), let expiresAt = epoch(zone.expiresAt) else { return nil }
        return ["zone",
                zone.id ?? "",
                zone.scopeType ?? "",
                zone.scopeValue ?? "",
                zone.delegatedAuthority ?? "",
                zone.delegateKeyId ?? "",
                zone.delegatePublicKey ?? "",
                zone.allowedHomeserverIds.map { JavaStringOrder.sorted($0).joined(separator: "|") } ?? "",
                String(notBefore),
                String(expiresAt)].joined(separator: separator)
    }

    private static func ruleLine(_ rule: RoutingPolicyRule) -> String {
        ["rule",
         rule.id ?? "",
         String(rule.priority),
         rule.matchType ?? "",
         rule.matchValue ?? "",
         rule.oidcIssuer ?? "",
         rule.oidcClaim ?? "",
         rule.targetHomeserverId ?? "",
         rule.delegatedZoneId ?? "",
         rule.reason ?? "",
         rule.effectiveAssignmentPolicy,
         rule.isEnabled ? "true" : "false"].joined(separator: separator)
    }

    static func epoch(_ iso: String?) -> Int64? {
        guard let iso else { return 0 }
        return ResolverInstant(iso: iso)?.epochMilliseconds
    }
}
