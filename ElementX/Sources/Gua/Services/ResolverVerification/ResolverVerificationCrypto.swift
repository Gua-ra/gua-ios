//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import CryptoKit
import Foundation

enum ResolverVerificationCrypto {
    static let spkiPrefix: [UInt8] = [0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x03, 0x21, 0x00]

    static func rawPublicKey(spkiBase64: String) -> [UInt8]? {
        guard let spki = Data(base64Encoded: spkiBase64), spki.count == 44 else { return nil }
        let bytes = [UInt8](spki)
        guard Array(bytes[0..<12]) == spkiPrefix else { return nil }
        let raw = Array(bytes[12...])
        guard Ed25519PublicKeyValidator.isValid(raw) else { return nil }
        return raw
    }

    static func publicKey(spkiBase64: String) -> Curve25519.Signing.PublicKey? {
        guard let raw = rawPublicKey(spkiBase64: spkiBase64) else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }

    static func verify(signatureBase64: String, over message: [UInt8], key: Curve25519.Signing.PublicKey) -> Bool {
        guard let signature = Data(base64Encoded: signatureBase64), signature.count == 64 else { return false }
        return key.isValidSignature(signature, for: message)
    }

    static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: bytes))
    }

    static func sha256Hex(_ bytes: [UInt8]) -> String {
        ResolverVerificationHex.string(sha256(bytes))
    }
}

enum ResolverVerificationHex {
    static func bytes(_ hex: String) -> [UInt8]? {
        let characters = Array(hex.utf8)
        guard characters.count.isMultiple(of: 2) else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(characters.count / 2)
        var index = 0
        while index < characters.count {
            guard let high = nibble(characters[index]), let low = nibble(characters[index + 1]) else { return nil }
            out.append(high << 4 | low)
            index += 2
        }
        return out
    }

    static func string(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        return String(unsafeUninitializedCapacity: bytes.count * 2) { buffer in
            for (offset, byte) in bytes.enumerated() {
                buffer[2 * offset] = digits[Int(byte >> 4)]
                buffer[2 * offset + 1] = digits[Int(byte & 0x0F)]
            }
            return bytes.count * 2
        }
    }

    private static func nibble(_ character: UInt8) -> UInt8? {
        switch character {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): character - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): character - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): character - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}

/// Java's `String.compareTo`, UTF-16 code unit order, which Swift's `String` comparison does not match above the BMP.
enum JavaStringOrder {
    static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.lexicographicallyPrecedes(rhs.utf16)
    }

    static func compare(_ lhs: String, _ rhs: String) -> Int {
        if precedes(lhs, rhs) { return -1 }
        if precedes(rhs, lhs) { return 1 }
        return 0
    }

    static func compare(_ lhs: String?, _ rhs: String?) -> Int {
        switch (lhs, rhs) {
        case (nil, nil): 0
        case (nil, _): 1
        case (_, nil): -1
        case let (lhs?, rhs?): compare(lhs, rhs)
        }
    }

    static func sorted(_ values: [String]) -> [String] {
        values.sorted(by: precedes)
    }
}
