//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// The `gua-lp.v1` length-prefixed canonical encoding: u32 big-endian lengths, int64 big-endian, a presence
/// byte for optionals, sets sorted by unsigned UTF-8 byte order. No delimiters, so no value can be confused
/// with framing.
struct GuaLPEncoder {
    enum EncodingError: Error, Equatable {
        case duplicateSetElement
        case missingRequiredValue
    }

    private(set) var bytes = [UInt8]()

    init() { }

    init(schemaTag: String) {
        string(schemaTag)
    }

    mutating func string(_ value: String) {
        let utf8 = Array(value.utf8)
        u32(utf8.count)
        bytes.append(contentsOf: utf8)
    }

    mutating func int64(_ value: Int64) {
        bytes.append(contentsOf: withUnsafeBytes(of: value.bigEndian, Array.init))
    }

    mutating func bool(_ value: Bool) {
        bytes.append(value ? 1 : 0)
    }

    mutating func optionalString(_ value: String?) {
        guard let value else {
            bytes.append(0)
            return
        }
        bytes.append(1)
        string(value)
    }

    mutating func enumName(_ name: String) {
        string(name)
    }

    mutating func stringList(_ values: [String]) {
        u32(values.count)
        for value in values {
            string(value)
        }
    }

    mutating func stringSet(_ values: [String]) throws {
        let encoded = values.map { Array($0.utf8) }.sorted { $0.lexicographicallyPrecedes($1) }
        for index in encoded.indices.dropFirst() where encoded[index - 1] == encoded[index] {
            throw EncodingError.duplicateSetElement
        }
        u32(encoded.count)
        for element in encoded {
            u32(element.count)
            bytes.append(contentsOf: element)
        }
    }

    private mutating func u32(_ count: Int) {
        bytes.append(contentsOf: withUnsafeBytes(of: UInt32(count).bigEndian, Array.init))
    }
}

/// The `gua-member-entry.v1` bytes a homeserver signs about itself. Field order follows the resolver's
/// `CanonicalMemberEntry`; `weight`, `acceptsNew`, `claims`, `admittedAt` and `status` are authority
/// attributes and are not covered.
enum CanonicalMemberEntry {
    static let schema = "gua-member-entry.v1"
    static let alg = "Ed25519"

    static func bytes(homeserver: RosterHomeserver, member: RosterMemberAttestation,
                      notBefore: Int64, notAfter: Int64) throws -> [UInt8] {
        guard let masIssuer = homeserver.masIssuer, let alg = member.alg,
              let signingKey = homeserver.signingKey, let keyId = member.keyId else {
            throw GuaLPEncoder.EncodingError.missingRequiredValue
        }
        var encoder = GuaLPEncoder(schemaTag: schema)
        encoder.string(homeserver.id)
        encoder.string(homeserver.serverName)
        encoder.string(homeserver.baseUrl)
        encoder.string(masIssuer)
        encoder.string(alg)
        encoder.string(signingKey)
        encoder.string(keyId)
        encoder.int64(member.sequence)
        encoder.int64(notBefore)
        encoder.int64(notAfter)
        encoder.optionalString(homeserver.region)
        encoder.enumName(homeserver.searchVisibility)
        try encoder.stringSet(homeserver.searchGroups)
        return encoder.bytes
    }
}

/// Verifies a member's self-signature over its roster entry, as the resolver's `MemberEntryVerifier` does.
/// Stateless: the caller passes the acceptance time and, when it holds one, the entry it last accepted for
/// the same homeserver id. The app holds no prior entries in v1.
enum MemberEntryVerifier {
    static let maxLifetimeMilliseconds: Int64 = 400 * 86_400_000

    enum Outcome: Equatable {
        case valid(entryHash: String)
        case unattested
        case invalid(reason: String)

        var isValid: Bool {
            if case .valid = self { return true }
            return false
        }
    }

    struct Prior {
        let keyId: String?
        let signingKey: String
        let sequence: Int64
        let entryHash: String?
    }

    static func verify(homeserver: RosterHomeserver, member: RosterMemberAttestation?,
                       atEpochMilliseconds at: Int64, prior: Prior? = nil) -> Outcome {
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
        let hash = ResolverVerificationCrypto.sha256Hex(canonical)

        guard let signingKey = homeserver.signingKey, let key = ResolverVerificationCrypto.publicKey(spkiBase64: signingKey) else {
            return .invalid(reason: "bad_signing_key")
        }
        guard let own = member.signatures.first(where: { $0.keyId == keyId }), let ownSignature = own.signatureB64 else {
            return .invalid(reason: "no_signature_by_key_id")
        }
        guard ResolverVerificationCrypto.verify(signatureBase64: ownSignature, over: canonical, key: key) else {
            return .invalid(reason: "bad_signature")
        }

        if let prior, let reason = continuityFailure(homeserver: homeserver, member: member, prior: prior, canonical: canonical, hash: hash) {
            return .invalid(reason: reason)
        }
        return .valid(entryHash: hash)
    }

    private static func continuityFailure(homeserver: RosterHomeserver, member: RosterMemberAttestation, prior: Prior,
                                          canonical: [UInt8], hash: String) -> String? {
        let keyChanged = homeserver.signingKey != prior.signingKey
        if member.sequence < prior.sequence { return "sequence_regression" }
        if member.sequence == prior.sequence {
            if keyChanged { return "rotation_needs_higher_sequence" }
            if let priorHash = prior.entryHash, priorHash != hash { return "sequence_reused" }
            return nil
        }
        guard keyChanged else { return nil }
        // Rotation: the previous key signs the same bytes and the new key gets its own id.
        if let priorKeyId = prior.keyId, priorKeyId == member.keyId { return "rotation_needs_new_key_id" }
        guard let previous = ResolverVerificationCrypto.publicKey(spkiBase64: prior.signingKey) else {
            return "no_previous_key"
        }
        let signedByPrevious = member.signatures.contains { signature in
            let fromPrevious = prior.keyId != nil ? signature.keyId == prior.keyId : signature.keyId != member.keyId
            guard fromPrevious, let value = signature.signatureB64 else { return false }
            return ResolverVerificationCrypto.verify(signatureBase64: value, over: canonical, key: previous)
        }
        return signedByPrevious ? nil : "rotation_not_signed_by_previous_key"
    }
}
