//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// Verifies a member's self-signature over its roster entry, as the resolver's `MemberEntryVerifier` does. The
/// app keeps no earlier entry, so key continuity is not checked.
enum MemberEntryVerifier {
    static let maxLifetimeMilliseconds: Int64 = 400 * 86_400_000

    enum Outcome: Equatable {
        case valid
        case unattested
        case invalid(reason: String)
    }

    static func verify(homeserver: RosterHomeserver, member: RosterMemberAttestation?, atEpochMilliseconds at: Int64) -> Outcome {
        guard let member else { return .unattested }
        guard member.schema == CanonicalMemberEntry.schema else { return .invalid(reason: "unsupported_schema") }
        guard member.alg == CanonicalMemberEntry.alg else { return .invalid(reason: "unsupported_alg") }
        guard let keyId = member.keyId, !keyId.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .invalid(reason: "missing_key_id")
        }
        guard member.sequence >= 1 else { return .invalid(reason: "bad_sequence") }

        guard let notBeforeIso = member.notBefore, let notAfterIso = member.notAfter,
              let notBefore = ResolverInstant(iso: notBeforeIso), let notAfter = ResolverInstant(iso: notAfterIso) else {
            return .invalid(reason: "bad_window")
        }
        guard !notBefore.hasSubMillisecondDigits, !notAfter.hasSubMillisecondDigits else {
            return .invalid(reason: "window_precision")
        }
        guard notAfter.epochMilliseconds > notBefore.epochMilliseconds else { return .invalid(reason: "bad_window") }
        guard notAfter.epochMilliseconds - notBefore.epochMilliseconds <= maxLifetimeMilliseconds else {
            return .invalid(reason: "window_too_long")
        }
        guard at >= notBefore.epochMilliseconds else { return .invalid(reason: "not_yet_valid") }
        guard at <= notAfter.epochMilliseconds else { return .invalid(reason: "expired") }

        guard !member.signatures.isEmpty else { return .invalid(reason: "no_signatures") }
        var seen = Set<String>()
        for signature in member.signatures {
            guard let signatureKeyId = signature.keyId, !signatureKeyId.trimmingCharacters(in: .whitespaces).isEmpty,
                  signature.signatureB64 != nil else {
                return .invalid(reason: "malformed_signature")
            }
            guard seen.insert(signatureKeyId).inserted else { return .invalid(reason: "duplicate_signature_key") }
        }

        let canonical: [UInt8]
        do {
            canonical = try CanonicalMemberEntry.bytes(homeserver: homeserver, member: member,
                                                       notBefore: notBefore.epochMilliseconds, notAfter: notAfter.epochMilliseconds)
        } catch {
            return .invalid(reason: "no_canonical_encoding")
        }
        guard let signingKey = homeserver.signingKey, let key = ResolverVerificationCrypto.publicKey(spkiBase64: signingKey) else {
            return .invalid(reason: "bad_signing_key")
        }
        guard let own = member.signatures.first(where: { $0.keyId == keyId }), let ownSignature = own.signatureB64 else {
            return .invalid(reason: "no_signature_by_key_id")
        }
        guard ResolverVerificationCrypto.verify(signatureBase64: ownSignature, over: canonical, key: key) else {
            return .invalid(reason: "bad_signature")
        }
        return .valid
    }
}
