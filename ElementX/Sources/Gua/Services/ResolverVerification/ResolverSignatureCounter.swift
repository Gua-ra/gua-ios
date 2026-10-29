//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import CryptoKit
import Foundation

/// Counts valid signatures over canonical bytes under trusted keys, one vote per key id.
enum ResolverSignatureCounter {
    struct Count: Equatable {
        /// Distinct trusted key ids whose signature verified.
        let valid: Int
        /// Signatures whose key id names a trusted key, whether or not they verified.
        let known: Int

        /// Why the signatures fall short of `threshold`, or `nil` when they meet it.
        func failureReason(threshold: Int) -> ResolverVerificationReason? {
            guard valid < threshold else { return nil }
            if known == 0 { return .unknownKeyId }
            return valid == 0 ? .badSignature : .thresholdNotMet
        }
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
