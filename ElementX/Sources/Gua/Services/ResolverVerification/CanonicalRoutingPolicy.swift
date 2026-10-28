//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import CryptoKit
import Foundation

/// The `gua-routing-policy.v1` and `gua-delegated-rules.v1` bytes, ports of the resolver's
/// `CanonicalRoutingPolicy` and `CanonicalDelegatedRules`. Signatures sit outside both.
enum CanonicalRoutingPolicy {
    private static let separator = "\u{1F}"

    /// `nil` when a timestamp the bytes carry does not parse.
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
        for zone in bundle.delegationZones.stableSorted(by: { JavaStringOrder.compare($0.id, $1.id) }) {
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

    /// The bytes a delegate signs for one zone: the bundle's rules whose `delegatedZoneId` is that zone.
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

    /// The rule order shared by the bundle and the per-zone form: priority, then id with nulls last.
    static func sortedRules(_ rules: [RoutingPolicyRule]) -> [RoutingPolicyRule] {
        rules.stableSorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority ? -1 : 1 }
            return JavaStringOrder.compare(lhs.id, rhs.id)
        }
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

    /// Epoch milliseconds, with `null` encoded as 0 and an unparseable value as `nil`.
    static func epoch(_ iso: String?) -> Int64? {
        guard let iso else { return 0 }
        return ResolverInstant(iso: iso)?.epochMilliseconds
    }
}

/// Counts valid signatures over canonical bytes under trusted keys, one vote per key id.
enum ResolverSignatureCounter {
    struct Count: Equatable {
        /// Distinct trusted key ids whose signature verified.
        let valid: Int
        /// Signatures whose key id names a trusted key, whether or not they verified.
        let known: Int
    }

    static func count(signatures: [(keyId: String?, signatureB64: String?)], over canonical: [UInt8],
                      keys: [String: Curve25519.Signing.PublicKey]) -> Count {
        var counted = Set<String>()
        var known = 0
        for signature in signatures {
            guard let keyId = signature.keyId, let key = keys[keyId] else { continue }
            known += 1
            guard !counted.contains(keyId), let value = signature.signatureB64,
                  ResolverVerificationCrypto.verify(signatureBase64: value, over: canonical, key: key) else {
                continue
            }
            counted.insert(keyId)
        }
        return Count(valid: counted.count, known: known)
    }

    /// Trusted keys by id, dropping any that is not a well formed Ed25519 SPKI document.
    static func keys(_ trusted: [ResolverTrustedKey]) -> [String: Curve25519.Signing.PublicKey] {
        var keys = [String: Curve25519.Signing.PublicKey]()
        for trustedKey in trusted {
            if let key = ResolverVerificationCrypto.publicKey(spkiBase64: trustedKey.publicKey) {
                keys[trustedKey.id] = key
            }
        }
        return keys
    }
}

/// Routing policy verification at both levels: the authority threshold over the whole bundle, then each zone's
/// delegate signature over its own rules. A rule is trusted only when its zone passes both.
enum RoutingPolicyVerifier {
    static func validSignatureCount(of bundle: RoutingPolicyBundle, canonical: [UInt8],
                                    keys: [String: Curve25519.Signing.PublicKey]) -> ResolverSignatureCounter.Count {
        ResolverSignatureCounter.count(signatures: bundle.signatures.map { ($0.authorityKeyId, $0.signatureB64) },
                                       over: canonical, keys: keys)
    }

    /// The zones whose rules carry a valid delegate signature under the zone's own `delegatePublicKey`. The
    /// bundle's authority signatures must already have been verified, which is what makes that key trusted.
    static func delegateVerifiedZones(of bundle: RoutingPolicyBundle) -> Set<String> {
        var verified = Set<String>()
        for zone in bundle.delegationZones {
            guard let zoneId = zone.id, let delegateKeyId = zone.delegateKeyId, !delegateKeyId.isBlank,
                  let delegatePublicKey = zone.delegatePublicKey, !delegatePublicKey.isBlank,
                  let key = ResolverVerificationCrypto.publicKey(spkiBase64: delegatePublicKey) else {
                continue
            }
            let canonical = CanonicalRoutingPolicy.delegatedRulesBytes(policyId: bundle.policyId, version: bundle.version,
                                                                       zoneId: zoneId, rules: bundle.rules)
            for signature in bundle.delegateSignatures where signature.zoneId == zoneId && signature.delegateKeyId == delegateKeyId {
                if let value = signature.signatureB64, ResolverVerificationCrypto.verify(signatureBase64: value, over: canonical, key: key) {
                    verified.insert(zoneId)
                    break
                }
            }
        }
        return verified
    }
}

private extension String {
    var isBlank: Bool {
        trimmingCharacters(in: .whitespaces).isEmpty
    }
}
