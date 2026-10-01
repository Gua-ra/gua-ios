//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import CryptoKit
import Foundation

/// Raw values match identity-service's rejection reason strings.
enum AccountGenesisError: String, Error, Equatable {
    case wrongLength = "wrong_length"
    case badMagic = "bad_magic"
    case unknownVersion = "unknown_version"
    case unknownSuite = "unknown_suite"
    case unknownRecoveryFramework = "unknown_recovery_framework"
    case zeroAuthorityKey = "zero_authority_key"
    case zeroRecoveryKey = "zero_recovery_key"
    case duplicateKeys = "duplicate_keys"
    case invalidAuthorityKey = "invalid_authority_key"
    case invalidRecoveryKey = "invalid_recovery_key"
    case badBase32 = "bad_base32"
    case badAccountID = "bad_account_id"
    case nonCanonicalAccountID = "non_canonical_account_id"
    case unknownRootClass = "unknown_root_class"
    case unknownAccountIDVersion = "unknown_account_id_version"

    var reason: String {
        rawValue
    }
}

// MARK: - Base32

/// Strict RFC 4648 base32, lowercase and unpadded, so each byte string has exactly one spelling.
enum GuaBase32 {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")

    private static let values: [Int8] = {
        var table = [Int8](repeating: -1, count: 128)
        for (index, character) in alphabet.enumerated() {
            if let ascii = character.asciiValue {
                table[Int(ascii)] = Int8(index)
            }
        }
        return table
    }()

    static func encode(_ data: [UInt8]) -> String {
        var out = ""
        out.reserveCapacity((data.count * 8 + 4) / 5)
        var buffer = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(buffer >> (bits - 5)) & 0x1F])
                bits -= 5
            }
        }
        if bits > 0 {
            out.append(alphabet[(buffer << (5 - bits)) & 0x1F])
        }
        return out
    }

    static func decode(_ encoded: String) throws -> [UInt8] {
        let remainder = encoded.count % 8
        // No byte string encodes to 1, 3 or 6 left-over characters.
        if remainder == 1 || remainder == 3 || remainder == 6 {
            throw AccountGenesisError.badBase32
        }

        var out = [UInt8]()
        out.reserveCapacity(encoded.count * 5 / 8)
        var buffer = 0
        var bits = 0
        for character in encoded.unicodeScalars {
            guard character.value < 128, values[Int(character.value)] >= 0 else {
                throw AccountGenesisError.badBase32
            }
            buffer = (buffer << 5) | Int(values[Int(character.value)])
            bits += 5
            if bits >= 8 {
                out.append(UInt8((buffer >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        // Non-zero trailing bits would give one byte string several spellings.
        if bits > 0, buffer & ((1 << bits) - 1) != 0 {
            throw AccountGenesisError.badBase32
        }
        return out
    }
}

// MARK: - accountId

/// `"ga1" || base32(0x01 || class || SHA-256(canonical bytes))`, hashed over the exact bytes received.
struct AccountID: Equatable {
    static let prefix = "ga1"

    static let formatVersion: UInt8 = 0x01

    static let classGenesis: UInt8 = 0x01

    static let classBootstrap: UInt8 = 0x00

    static let rawLength = 34

    static let encodedLength = 55

    static let length = prefix.count + encodedLength

    /// The last character carries three unused bits, so only `a`, `i`, `q` and `y` are canonical.
    static let canonicalPattern = "^ga1[a-z2-7]{54}[aiqy]$"

    let value: String
    let rawBytes: [UInt8]

    static func derive(rootClass: UInt8, canonicalBytes: [UInt8]) throws -> AccountID {
        try requireKnownClass(rootClass)
        var raw = [UInt8]()
        raw.reserveCapacity(rawLength)
        raw.append(formatVersion)
        raw.append(rootClass)
        raw.append(contentsOf: SHA256.hash(data: Data(canonicalBytes)))
        return AccountID(value: prefix + GuaBase32.encode(raw), rawBytes: raw)
    }

    static func parse(_ value: String) throws -> AccountID {
        guard value.range(of: canonicalPattern, options: .regularExpression) != nil else {
            throw AccountGenesisError.badAccountID
        }
        let encoded = String(value.dropFirst(prefix.count))
        let raw: [UInt8]
        do {
            raw = try GuaBase32.decode(encoded)
        } catch {
            throw AccountGenesisError.badAccountID
        }
        guard raw.count == rawLength else { throw AccountGenesisError.badAccountID }
        guard GuaBase32.encode(raw) == encoded else { throw AccountGenesisError.nonCanonicalAccountID }
        guard raw[0] == formatVersion else { throw AccountGenesisError.unknownAccountIDVersion }
        try requireKnownClass(raw[1])
        return AccountID(value: value, rawBytes: raw)
    }

    var rootClass: UInt8 {
        rawBytes[1]
    }

    var isGenesisRooted: Bool {
        rootClass == Self.classGenesis
    }

    private static func requireKnownClass(_ rootClass: UInt8) throws {
        guard rootClass == classGenesis || rootClass == classBootstrap else {
            throw AccountGenesisError.unknownRootClass
        }
    }
}

// MARK: - AccountGenesis

/// Canonical fixed-width encoding. The accountId hashes the exact bytes received.
struct AccountGenesis: Equatable {
    static let length = 87

    static let magic: [UInt8] = Array("GUAG".utf8)

    static let version: UInt8 = 0x01

    static let suiteEd25519SHA256: UInt8 = 0x01

    static let recoveryFrameworkCommittedKey: UInt8 = 0x01

    static let entropyLength = 16

    static let publicKeyLength = 32

    private static let offsetVersion = 4
    private static let offsetSuite = 5
    private static let offsetAuthorityKey = 6
    private static let offsetFramework = 38
    private static let offsetRecoveryKey = 39
    private static let offsetEntropy = 71

    let genesisVersion: UInt8
    let suite: UInt8
    let authorityPublicKey: [UInt8]
    let recoveryFrameworkID: UInt8
    let recoveryAuthorityPublicKey: [UInt8]
    let entropy: [UInt8]
    let canonicalBytes: [UInt8]

    func accountID() throws -> AccountID {
        try AccountID.derive(rootClass: AccountID.classGenesis, canonicalBytes: canonicalBytes)
    }

    static func encode(authorityPublicKey: [UInt8],
                       recoveryFrameworkID: UInt8 = recoveryFrameworkCommittedKey,
                       recoveryAuthorityPublicKey: [UInt8],
                       entropy: [UInt8]) throws -> [UInt8] {
        guard authorityPublicKey.count == publicKeyLength,
              recoveryAuthorityPublicKey.count == publicKeyLength,
              entropy.count == entropyLength else {
            throw AccountGenesisError.wrongLength
        }
        var out = [UInt8]()
        out.reserveCapacity(length)
        out.append(contentsOf: magic)
        out.append(version)
        out.append(suiteEd25519SHA256)
        out.append(contentsOf: authorityPublicKey)
        out.append(recoveryFrameworkID)
        out.append(contentsOf: recoveryAuthorityPublicKey)
        out.append(contentsOf: entropy)
        return out
    }

    /// The all-zero check is separate from point decoding: all-zero bytes decode to a valid low-order point.
    static func decode(_ bytes: [UInt8]) throws -> AccountGenesis {
        guard bytes.count == length else { throw AccountGenesisError.wrongLength }
        guard Array(bytes[0..<magic.count]) == magic else { throw AccountGenesisError.badMagic }
        guard bytes[offsetVersion] == version else { throw AccountGenesisError.unknownVersion }
        guard bytes[offsetSuite] == suiteEd25519SHA256 else { throw AccountGenesisError.unknownSuite }
        guard bytes[offsetFramework] == recoveryFrameworkCommittedKey else {
            throw AccountGenesisError.unknownRecoveryFramework
        }

        let authorityKey = Array(bytes[offsetAuthorityKey..<offsetFramework])
        let recoveryKey = Array(bytes[offsetRecoveryKey..<offsetEntropy])
        let entropy = Array(bytes[offsetEntropy..<length])

        guard authorityKey.contains(where: { $0 != 0 }) else { throw AccountGenesisError.zeroAuthorityKey }
        guard recoveryKey.contains(where: { $0 != 0 }) else { throw AccountGenesisError.zeroRecoveryKey }
        guard authorityKey != recoveryKey else { throw AccountGenesisError.duplicateKeys }
        guard Ed25519PublicKeyValidator.isValid(authorityKey) else {
            throw AccountGenesisError.invalidAuthorityKey
        }
        guard Ed25519PublicKeyValidator.isValid(recoveryKey) else {
            throw AccountGenesisError.invalidRecoveryKey
        }

        return AccountGenesis(genesisVersion: bytes[offsetVersion],
                              suite: bytes[offsetSuite],
                              authorityPublicKey: authorityKey,
                              recoveryFrameworkID: bytes[offsetFramework],
                              recoveryAuthorityPublicKey: recoveryKey,
                              entropy: entropy,
                              canonicalBytes: bytes)
    }
}

// MARK: - BootstrapGenesis

/// Created only by identity-service; the client decodes it to re-derive a bootstrap accountId.
struct BootstrapGenesis: Equatable {
    static let length = 22
    static let magic: [UInt8] = Array("GUAB".utf8)
    static let version: UInt8 = 0x01
    static let suiteNone: UInt8 = 0x00
    static let entropyLength = 16

    let version: UInt8
    let suite: UInt8
    let entropy: [UInt8]
    let canonicalBytes: [UInt8]

    func accountID() throws -> AccountID {
        try AccountID.derive(rootClass: AccountID.classBootstrap, canonicalBytes: canonicalBytes)
    }

    static func decode(_ bytes: [UInt8]) throws -> BootstrapGenesis {
        guard bytes.count == length else { throw AccountGenesisError.wrongLength }
        guard Array(bytes[0..<magic.count]) == magic else { throw AccountGenesisError.badMagic }
        guard bytes[4] == version else { throw AccountGenesisError.unknownVersion }
        guard bytes[5] == suiteNone else { throw AccountGenesisError.unknownSuite }
        return BootstrapGenesis(version: bytes[4],
                                suite: bytes[5],
                                entropy: Array(bytes[6..<length]),
                                canonicalBytes: bytes)
    }
}

// MARK: - Proofs

/// Signature preimages for the registration and attach proofs. Every field is fixed length.
enum GenesisProofs {
    static let genesisProofDomain = "gua-account-genesis-proof.v1"

    static let attachProofDomain = "gua-account-attach-proof.v1"

    static let attachChallengeLength = 32

    static let attachPreimageLength = attachProofDomain.utf8.count + attachChallengeLength + AccountID.rawLength

    static func genesisProofPreimage(canonicalBytes: [UInt8]) -> [UInt8] {
        Array(genesisProofDomain.utf8) + canonicalBytes
    }

    static func attachProofPreimage(challenge: [UInt8], accountID: AccountID) throws -> [UInt8] {
        guard challenge.count == attachChallengeLength else { throw AccountGenesisError.wrongLength }
        return Array(attachProofDomain.utf8) + challenge + accountID.rawBytes
    }
}

// MARK: - Ed25519 point validation

/// CryptoKit accepts any 32 bytes as a public key and only fails at verification, so point decoding is done here.
/// Inputs are public keys, so the arithmetic is not constant time.
enum Ed25519PublicKeyValidator {
    static func isValid(_ raw: [UInt8]) -> Bool {
        guard raw.count == 32 else { return false }
        var yBytes = raw
        let sign = (yBytes[31] >> 7) & 1
        yBytes[31] &= 0x7F
        let y = Field(yBytes)
        // A y at or above the field prime is a second spelling of a smaller y.
        guard Field.compare(y, Field.prime) < 0 else { return false }

        let yy = Field.multiply(y, y)
        let u = Field.subtract(yy, Field.one)
        let v = Field.add(Field.multiply(Field.d, yy), Field.one)

        // x = u * v^3 * (u * v^7)^((p-5)/8)
        let v2 = Field.multiply(v, v)
        let v3 = Field.multiply(v2, v)
        let v4 = Field.multiply(v2, v2)
        let v7 = Field.multiply(v3, v4)
        var x = Field.multiply(Field.multiply(u, v3), Field.power(Field.multiply(u, v7), Field.pMinus5Over8))

        var check = Field.multiply(v, Field.multiply(x, x))
        if Field.compare(check, u) != 0 {
            // The other root: x * sqrt(-1) when v * x^2 == -u, and no square root at all otherwise.
            guard Field.compare(check, Field.subtract(Field.zero, u)) == 0 else { return false }
            x = Field.multiply(x, Field.sqrtMinus1)
            check = Field.multiply(v, Field.multiply(x, x))
            guard Field.compare(check, u) == 0 else { return false }
        }

        // x == 0 with the sign bit set is the one encoding with no point behind it.
        if x.isZero, sign == 1 { return false }
        return true
    }

    /// A field element mod `p = 2^255 - 19`, four 64-bit limbs, least significant first.
    private struct Field {
        var limbs: [UInt64]

        init(limbs: [UInt64]) {
            self.limbs = limbs
        }

        init(_ bytes: [UInt8]) {
            var out = [UInt64](repeating: 0, count: 4)
            for index in 0..<4 {
                var word: UInt64 = 0
                for byte in 0..<8 {
                    word |= UInt64(bytes[index * 8 + byte]) << (8 * UInt64(byte))
                }
                out[index] = word
            }
            limbs = out
        }

        var isZero: Bool {
            limbs.allSatisfy { $0 == 0 }
        }

        static let zero = Field(limbs: [0, 0, 0, 0])
        static let one = Field(limbs: [1, 0, 0, 0])

        static let prime = Field(limbs: [0xFFFF_FFFF_FFFF_FFED, 0xFFFF_FFFF_FFFF_FFFF,
                                         0xFFFF_FFFF_FFFF_FFFF, 0x7FFF_FFFF_FFFF_FFFF])

        /// `d = -121665/121666 mod p`, the Edwards curve constant.
        static let d = Field(limbs: [0x75EB_4DCA_1359_78A3, 0x0070_0A4D_4141_D8AB,
                                     0x8CC7_4079_7779_E898, 0x5203_6CEE_2B6F_FE73])

        static let sqrtMinus1 = Field(limbs: [0xC4EE_1B27_4A0E_A0B0, 0x2F43_1806_AD2F_E478,
                                              0x2B4D_0099_3DFB_D7A7, 0x2B83_2480_4FC1_DF0B])

        /// Little-endian bytes.
        static let pMinus5Over8: [UInt8] = [0xFD] + [UInt8](repeating: 0xFF, count: 30) + [0x0F]

        static func compare(_ lhs: Field, _ rhs: Field) -> Int {
            for index in stride(from: 3, through: 0, by: -1) where lhs.limbs[index] != rhs.limbs[index] {
                return lhs.limbs[index] < rhs.limbs[index] ? -1 : 1
            }
            return 0
        }

        static func add(_ lhs: Field, _ rhs: Field) -> Field {
            var out = [UInt64](repeating: 0, count: 4)
            var carry: UInt64 = 0
            for index in 0..<4 {
                let (partial, overflow1) = lhs.limbs[index].addingReportingOverflow(rhs.limbs[index])
                let (sum, overflow2) = partial.addingReportingOverflow(carry)
                out[index] = sum
                carry = (overflow1 ? 1 : 0) &+ (overflow2 ? 1 : 0)
            }
            var result = Field(limbs: out)
            if carry != 0 || compare(result, prime) >= 0 {
                result = subtractRaw(result, prime)
            }
            return result
        }

        static func subtract(_ lhs: Field, _ rhs: Field) -> Field {
            var out = [UInt64](repeating: 0, count: 4)
            var borrow: UInt64 = 0
            for index in 0..<4 {
                let (partial, underflow1) = lhs.limbs[index].subtractingReportingOverflow(rhs.limbs[index])
                let (difference, underflow2) = partial.subtractingReportingOverflow(borrow)
                out[index] = difference
                borrow = (underflow1 ? 1 : 0) &+ (underflow2 ? 1 : 0)
            }
            var result = Field(limbs: out)
            if borrow != 0 {
                result = addRaw(result, prime)
            }
            return result
        }

        static func multiply(_ lhs: Field, _ rhs: Field) -> Field {
            var product = [UInt64](repeating: 0, count: 8)
            for i in 0..<4 {
                var carry: UInt64 = 0
                for j in 0..<4 {
                    let (high, low) = lhs.limbs[i].multipliedFullWidth(by: rhs.limbs[j])
                    let (partial, overflow1) = product[i + j].addingReportingOverflow(low)
                    let (sum, overflow2) = partial.addingReportingOverflow(carry)
                    product[i + j] = sum
                    carry = high &+ (overflow1 ? 1 : 0) &+ (overflow2 ? 1 : 0)
                }
                var index = i + 4
                while carry != 0, index < 8 {
                    let (sum, overflow) = product[index].addingReportingOverflow(carry)
                    product[index] = sum
                    carry = overflow ? 1 : 0
                    index += 1
                }
            }
            // Fold the high half back in: 2^256 == 38 (mod p).
            var accumulator = Field(limbs: Array(product[0..<4]))
            var overflowWords = Array(product[4..<8])
            for _ in 0..<4 {
                if overflowWords.allSatisfy({ $0 == 0 }) { break }
                var scaled = [UInt64](repeating: 0, count: 5)
                var carry: UInt64 = 0
                for index in 0..<4 {
                    let (high, low) = overflowWords[index].multipliedFullWidth(by: 38)
                    let (sum, overflow) = low.addingReportingOverflow(carry)
                    scaled[index] = sum
                    carry = high &+ (overflow ? 1 : 0)
                }
                scaled[4] = carry
                var nextCarry: UInt64 = 0
                var sums = accumulator.limbs
                for index in 0..<4 {
                    let (partial, overflow1) = sums[index].addingReportingOverflow(scaled[index])
                    let (sum, overflow2) = partial.addingReportingOverflow(nextCarry)
                    sums[index] = sum
                    nextCarry = (overflow1 ? 1 : 0) &+ (overflow2 ? 1 : 0)
                }
                accumulator = Field(limbs: sums)
                overflowWords = [scaled[4] &+ nextCarry, 0, 0, 0]
            }
            while compare(accumulator, prime) >= 0 {
                accumulator = subtractRaw(accumulator, prime)
            }
            return accumulator
        }

        static func power(_ base: Field, _ exponent: [UInt8]) -> Field {
            var result = one
            var running = base
            for byte in exponent {
                for bit in 0..<8 {
                    if (byte >> UInt8(bit)) & 1 == 1 {
                        result = multiply(result, running)
                    }
                    running = multiply(running, running)
                }
            }
            return result
        }

        /// The caller guarantees `lhs >= rhs`.
        private static func subtractRaw(_ lhs: Field, _ rhs: Field) -> Field {
            var out = [UInt64](repeating: 0, count: 4)
            var borrow: UInt64 = 0
            for index in 0..<4 {
                let (partial, underflow1) = lhs.limbs[index].subtractingReportingOverflow(rhs.limbs[index])
                let (difference, underflow2) = partial.subtractingReportingOverflow(borrow)
                out[index] = difference
                borrow = (underflow1 ? 1 : 0) &+ (underflow2 ? 1 : 0)
            }
            return Field(limbs: out)
        }

        private static func addRaw(_ lhs: Field, _ rhs: Field) -> Field {
            var out = [UInt64](repeating: 0, count: 4)
            var carry: UInt64 = 0
            for index in 0..<4 {
                let (partial, overflow1) = lhs.limbs[index].addingReportingOverflow(rhs.limbs[index])
                let (sum, overflow2) = partial.addingReportingOverflow(carry)
                out[index] = sum
                carry = (overflow1 ? 1 : 0) &+ (overflow2 ? 1 : 0)
            }
            return Field(limbs: out)
        }
    }
}
