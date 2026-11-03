//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import CryptoKit
import Foundation

enum RoutingPolicyVerifier {
    static func validSignatureCount(of bundle: RoutingPolicyBundle, canonical: [UInt8],
                                    keys: [String: Curve25519.Signing.PublicKey]) -> ResolverSignatureCounter.Count {
        ResolverSignatureCounter.count(signatures: bundle.signatures.map { ($0.authorityKeyId, $0.signatureB64) },
                                       over: canonical, keys: keys)
    }

    /// Each `delegatePublicKey` is trusted only through the bundle's authority signatures, so those must verify first.
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
