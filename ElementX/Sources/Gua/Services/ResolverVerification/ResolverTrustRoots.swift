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

    /// Production lists no policy keys until governance keys exist, so a policy served there is `no_policy_keys`.
    static let production = ResolverTrustRoots(authorityKeys: [ResolverTrustedKey(id: "gua-authority-prod",
                                                                                  publicKey: "MCowBQYDK2VwAyEAmrJntRXbxGkoPe92j1epyM3RBXcx4nmr2wIzL6eb0a0=")],
                                               authorityThreshold: 1, policyKeys: [], policyThreshold: 1)

    init(authorityKeys: [ResolverTrustedKey], authorityThreshold: Int,
         policyKeys: [ResolverTrustedKey], policyThreshold: Int) {
        self.authorityKeys = authorityKeys
        self.authorityThreshold = max(1, authorityThreshold)
        self.policyKeys = policyKeys
        self.policyThreshold = max(1, policyThreshold)
    }

    /// Development roots in Android's format: whitespace-separated `authority:<keyId>:<spkiBase64>`,
    /// `policy:<keyId>:<spkiBase64>`, `authority-threshold:<n>` and `policy-threshold:<n>`, thresholds 1 by default.
    /// A value with any token that does not read is refused whole and gives `.empty`.
    init(developmentSecret value: String?) {
        var authorityKeys = [ResolverTrustedKey]()
        var policyKeys = [ResolverTrustedKey]()
        var authorityThreshold = 1
        var policyThreshold = 1
        for token in (value ?? "").split(whereSeparator: \.isWhitespace) {
            let parts = token.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            switch (parts[0], parts.count) {
            case ("authority", 3):
                guard let key = Self.key(id: parts[1], publicKey: parts[2]) else { self = .empty; return }
                authorityKeys.append(key)
            case ("policy", 3):
                guard let key = Self.key(id: parts[1], publicKey: parts[2]) else { self = .empty; return }
                policyKeys.append(key)
            case ("authority-threshold", 2):
                guard let threshold = Int(parts[1]), threshold >= 1 else { self = .empty; return }
                authorityThreshold = threshold
            case ("policy-threshold", 2):
                guard let threshold = Int(parts[1]), threshold >= 1 else { self = .empty; return }
                policyThreshold = threshold
            default:
                self = .empty
                return
            }
        }
        self.init(authorityKeys: authorityKeys, authorityThreshold: authorityThreshold, policyKeys: policyKeys, policyThreshold: policyThreshold)
    }

    private static func key(id: String, publicKey: String) -> ResolverTrustedKey? {
        guard !id.isEmpty, ResolverVerificationCrypto.publicKey(spkiBase64: publicKey) != nil else { return nil }
        return ResolverTrustedKey(id: id, publicKey: publicKey)
    }
}
