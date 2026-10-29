//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// The `gua-lp.v1` encoding: u32 big-endian lengths, int64 big-endian, a presence byte for optionals and sets in
/// unsigned UTF-8 byte order. It has no delimiters, so no value can be confused with framing.
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

/// The `gua-member-entry.v1` bytes a homeserver signs about itself, in the resolver's field order. The authority
/// attributes `weight`, `acceptsNew`, `claims`, `admittedAt` and `status` are not covered.
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
