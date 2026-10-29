//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// A published Ed25519 key the resolver's artifacts are verified under. `publicKey` is the base64 X.509
/// SubjectPublicKeyInfo, the same encoding the roster carries for homeserver signing keys.
struct ResolverTrustedKey: Equatable {
    let id: String
    let publicKey: String
}

/// The keys pinned per deployment for the roster (authority) and the routing policy. The policy list has
/// no fallback to the authority list: an empty one verifies no policy.
struct ResolverTrustRoots: Equatable {
    let authorityKeys: [ResolverTrustedKey]
    let authorityThreshold: Int
    let policyKeys: [ResolverTrustedKey]
    let policyThreshold: Int

    /// No keys at all: the verifier reports every answer as unverifiable and fetches nothing.
    static let empty = ResolverTrustRoots(authorityKeys: [], authorityThreshold: 1, policyKeys: [], policyThreshold: 1)

    /// The production authority key. Production serves no policy today; the same key is listed as the
    /// policy key so the development and production configurations have the same shape.
    static let production: ResolverTrustRoots = {
        let authority = ResolverTrustedKey(id: "gua-authority-prod",
                                           publicKey: "MCowBQYDK2VwAyEAmrJntRXbxGkoPe92j1epyM3RBXcx4nmr2wIzL6eb0a0=")
        return ResolverTrustRoots(authorityKeys: [authority], authorityThreshold: 1,
                                  policyKeys: [authority], policyThreshold: 1)
    }()

    /// Development roots from the injected secret: `keyId:spkiBase64` pairs separated by commas, each key
    /// listed as both an authority and a policy key with threshold 1. Empty or malformed yields `.empty`.
    init(developmentSecret value: String?) {
        let keys = Self.keys(from: value) ?? []
        self.init(authorityKeys: keys, authorityThreshold: 1, policyKeys: keys, policyThreshold: 1)
    }

    init(authorityKeys: [ResolverTrustedKey], authorityThreshold: Int,
         policyKeys: [ResolverTrustedKey], policyThreshold: Int) {
        self.authorityKeys = authorityKeys
        self.authorityThreshold = max(1, authorityThreshold)
        self.policyKeys = policyKeys
        self.policyThreshold = max(1, policyThreshold)
    }

    private static func keys(from value: String?) -> [ResolverTrustedKey]? {
        var keys = [ResolverTrustedKey]()
        for pair in (value ?? "").split(separator: ",") {
            let parts = pair.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            keys.append(ResolverTrustedKey(id: parts[0], publicKey: parts[1]))
        }
        return keys
    }
}
