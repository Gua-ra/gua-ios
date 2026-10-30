//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// A port of the resolver's `MemberEntryVerifier` without key continuity, since the app keeps no earlier entry.
enum MemberEntryVerifier {
    static let maxLifetimeMilliseconds: Int64 = 400 * 86_400_000

    static func verify(homeserver: RosterHomeserver, member: RosterMemberAttestation?,
                       atEpochMilliseconds now: Int64) -> ResolverVerificationReport.MemberEntry {
        guard let member else { return .unattested }
        do {
            try check(member, of: homeserver, at: now)
            return .valid
        } catch {
            return .invalid(error)
        }
    }

    private static func check(_ member: RosterMemberAttestation, of homeserver: RosterHomeserver,
                              at now: Int64) throws(ResolverVerificationReason) {
        guard member.schema == CanonicalMemberEntry.schema else { throw .unsupportedSchema }
        guard member.alg == CanonicalMemberEntry.alg else { throw .unsupportedAlg }
        guard let keyId = member.keyId, !keyId.isBlank else { throw .badKeyId }
        guard member.sequence >= 1 else { throw .badSequence }
        let window = try validityWindow(of: member)
        guard window.contains(now) else { throw .outsideWindow }
        try checkSignatureShape(member.signatures)
        guard let canonical = try? CanonicalMemberEntry.bytes(homeserver: homeserver, member: member,
                                                              notBefore: window.lowerBound, notAfter: window.upperBound) else {
            throw .noCanonicalEncoding
        }
        guard let signingKey = homeserver.signingKey, let key = ResolverVerificationCrypto.publicKey(spkiBase64: signingKey) else {
            throw .badSigningKey
        }
        guard let own = member.signatures.first(where: { $0.keyId == keyId })?.signatureB64 else { throw .missingSignature }
        guard ResolverVerificationCrypto.verify(signatureBase64: own, over: canonical, key: key) else { throw .badSignature }
    }

    private static func validityWindow(of member: RosterMemberAttestation) throws(ResolverVerificationReason) -> ClosedRange<Int64> {
        guard let notBefore = member.notBefore, let notAfter = member.notAfter else { throw .badWindow }
        guard let start = ResolverInstant(iso: notBefore), let end = ResolverInstant(iso: notAfter) else { throw .parseError }
        guard !start.hasSubMillisecondDigits, !end.hasSubMillisecondDigits, start.epochMilliseconds < end.epochMilliseconds,
              end.epochMilliseconds - start.epochMilliseconds <= maxLifetimeMilliseconds else {
            throw .badWindow
        }
        return start.epochMilliseconds...end.epochMilliseconds
    }

    private static func checkSignatureShape(_ signatures: [RosterMemberSignature]) throws(ResolverVerificationReason) {
        var keyIds = Set<String>()
        for signature in signatures {
            guard let keyId = signature.keyId, !keyId.isBlank, signature.signatureB64 != nil, keyIds.insert(keyId).inserted else {
                throw .malformedSignature
            }
        }
        guard !keyIds.isEmpty else { throw .malformedSignature }
    }
}
