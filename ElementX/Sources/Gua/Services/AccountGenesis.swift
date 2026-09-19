//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import CryptoKit
import Foundation

/// Why a set of canonical bytes, or an accountId, was refused.
///
/// The raw values are the reason strings the golden vectors name
/// (`docs/specs/genesis-vectors.v1.json` in identity-service), so a vector's expected reason can be
/// compared against what this codec produced without a translation table in the middle.
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

    /// The reason string, matching identity-service's `InvalidGenesisException.reason()`.
    var reason: String {
        rawValue
    }
}

// MARK: - Base32

/// RFC 4648 base32, lowercase and unpadded, the spelling ADM-008 decision 2 fixes for an accountId.
///
/// The decoder is strict in the three directions an ambiguity could enter: only the lowercase
/// alphabet, only a character count an unpadded encoding can produce, and only zero trailing bits.
/// Each of those is a way one byte string would otherwise gain several spellings, which ADM-001 L4
/// forbids for anything a permanent identifier covers.
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
            // Left-over bits are left aligned and zero padded on the right.
            out.append(alphabet[(buffer << (5 - bits)) & 0x1F])
        }
        return out
    }

    static func decode(_ encoded: String) throws -> [UInt8] {
        let remainder = encoded.count % 8
        // 1, 3 and 6 left-over characters cannot come out of any byte string.
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
        // Whatever is left over is padding and must be zero, or one byte string has several spellings.
        if bits > 0, buffer & ((1 << bits) - 1) != 0 {
            throw AccountGenesisError.badBase32
        }
        return out
    }
}

// MARK: - accountId

/// An accountId: `"ga1" || base32(0x01 || class || SHA-256(canonical bytes))` (ADM-008 decision 2).
///
/// The digest covers the canonical bytes *as received*. Nothing here re-encodes a decoded object
/// before hashing it: the accountId is permanent, so if the bytes that were hashed were not the bytes
/// that crossed the wire, a decoder bug would silently mint a different account.
///
/// An accountId also has exactly one spelling. The 34 input bytes are 272 bits while the 55 base32
/// characters carry 275, so the last character holds three unused bits and only `a`, `i`, `q` and `y`
/// can end a well-formed id. ``parse(_:)`` applies the tightened pattern, decodes, re-encodes and
/// compares.
struct AccountID: Equatable {
    static let prefix = "ga1"

    /// accountId format version, the first byte under the base32.
    static let formatVersion: UInt8 = 0x01

    /// Root class byte: the account is rooted in an `AccountGenesis`.
    static let classGenesis: UInt8 = 0x01

    /// Root class byte: the account is a bootstrap account (ADM-001 L5 path B1).
    static let classBootstrap: UInt8 = 0x00

    /// Bytes under the base32: format version, root class, then the 32-byte digest.
    static let rawLength = 34

    /// Characters of base32 that ``rawLength`` bytes produce.
    static let encodedLength = 55

    /// Total characters, the `ga1` prefix included.
    static let length = prefix.count + encodedLength

    /// The canonical spelling, tightened at the last character.
    static let canonicalPattern = "^ga1[a-z2-7]{54}[aiqy]$"

    let value: String
    let rawBytes: [UInt8]

    /// Derives the accountId of an object from the exact bytes received for it.
    ///
    /// - Parameters:
    ///   - rootClass: ``classGenesis`` or ``classBootstrap``
    ///   - canonicalBytes: the canonical bytes as received, never a re-encoding of a parsed object
    static func derive(rootClass: UInt8, canonicalBytes: [UInt8]) throws -> AccountID {
        try requireKnownClass(rootClass)
        var raw = [UInt8]()
        raw.reserveCapacity(rawLength)
        raw.append(formatVersion)
        raw.append(rootClass)
        raw.append(contentsOf: SHA256.hash(data: Data(canonicalBytes)))
        return AccountID(value: prefix + GuaBase32.encode(raw), rawBytes: raw)
    }

    /// Parses an accountId, enforcing the canonical form.
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
        // The pattern already excludes the seven non-canonical last characters; re-encoding and
        // comparing is the rule ADM-008 decision 2 states, and it also catches any future change to
        // either routine.
        guard GuaBase32.encode(raw) == encoded else { throw AccountGenesisError.nonCanonicalAccountID }
        guard raw[0] == formatVersion else { throw AccountGenesisError.unknownAccountIDVersion }
        try requireKnownClass(raw[1])
        return AccountID(value: value, rawBytes: raw)
    }

    /// ``classGenesis`` or ``classBootstrap``.
    var rootClass: UInt8 {
        rawBytes[1]
    }

    /// True for a genesis-rooted account, false for a bootstrap one (ADM-001 L5's audit marker).
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

/// A decoded `AccountGenesis` (ADM-008 suite 0x01) together with the exact bytes it was decoded from.
///
/// It commits the initial authority key, the algorithm identifiers, and the initial recovery authority
/// and framework. It holds no identifier and no homeserver (ADM-001 L4).
///
/// The layout is fixed and has no delimiters, which is what ADM-008 chose over ADM-007's `gua-lp.v1`
/// framing for account objects: they carry no optional fields, no sets and no free strings, and the
/// accountId is a permanent hash of these bytes, so the bytes that are hashed have to be the bytes that
/// crossed the wire.
///
/// ```
/// off len field
/// 0   4   magic "GUAG"
/// 4   1   genesisVersion = 0x01
/// 5   1   suite = 0x01
/// 6   32  authorityPublicKey          raw RFC 8032 Ed25519
/// 38  1   recoveryFrameworkId = 0x01
/// 39  32  recoveryAuthorityPublicKey  raw Ed25519, must differ from the authority key
/// 71  16  entropy                     CSPRNG
/// 87      end
/// ```
struct AccountGenesis: Equatable {
    /// Total canonical length. Any other length is rejected.
    static let length = 87

    /// ASCII `GUAG`, the domain separator.
    static let magic: [UInt8] = Array("GUAG".utf8)

    static let version: UInt8 = 0x01

    /// Ed25519 authority, Ed25519 recovery, SHA-256.
    static let suiteEd25519SHA256: UInt8 = 0x01

    /// One committed recovery authority key (ADM-008 decision 4).
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
    /// The bytes as received. The accountId is the hash of these, never of a re-encoding.
    let canonicalBytes: [UInt8]

    /// Genesis-rooted accountId over the received bytes.
    func accountID() throws -> AccountID {
        try AccountID.derive(rootClass: AccountID.classGenesis, canonicalBytes: canonicalBytes)
    }

    /// Builds canonical bytes.
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

    /// Strictly decodes canonical bytes, keeping them exactly as passed in so the accountId is derived
    /// from what was received.
    ///
    /// Rejects an unknown version, suite or framework, a wrong length, an all-zero key, equal authority
    /// and recovery keys, and a key that fails Ed25519 point decoding. The all-zero rule is separate
    /// from point decoding on purpose: the all-zero encoding decodes to a valid low-order point.
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

/// A `BootstrapGenesis` (ADM-008 suite 0x00). The client never mints one: identity-service does that
/// for a signup that presented no handle (ADM-001 L5 path B1). The codec is here so the client can
/// recognise and re-derive a bootstrap id, and so the golden vectors covering it are exercised.
///
/// ```
/// off len field
/// 0   4   magic "GUAB"
/// 4   1   version = 0x01
/// 5   1   suite = 0x00
/// 6   16  entropy     CSPRNG, never derived from the MXID or phone
/// 22      end
/// ```
struct BootstrapGenesis: Equatable {
    static let length = 22
    static let magic: [UInt8] = Array("GUAB".utf8)
    static let version: UInt8 = 0x01
    /// No authority key.
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

/// The two possession proofs ADM-008 defines, and the fixed-length preimages they cover.
///
/// **Registration proof** (decision 3). An Ed25519 signature by the authority key over the ASCII domain
/// `gua-account-genesis-proof.v1` followed by the canonical bytes. It proves the registrant holds the
/// key and is not part of the genesis. No identifier appears in the preimage: an MXID there would put
/// an identifier into the id.
///
/// **Attach proof** (decision 6). An Ed25519 signature by the same committed authority key over the
/// domain `gua-account-attach-proof.v1`, then the 32 server-chosen challenge bytes, then the 34 raw
/// accountId bytes. Every element is fixed length, so no field can be shifted into another: 27 + 32 +
/// 34. A handle alone attaches nothing, because anyone can compose an authorize URL carrying someone
/// else's handle; only this signature shows that the party which registered the genesis held its key
/// and was present in this login session.
enum GenesisProofs {
    /// 28 ASCII bytes.
    static let genesisProofDomain = "gua-account-genesis-proof.v1"

    /// 27 ASCII bytes, as ADM-008 decision 6 states.
    static let attachProofDomain = "gua-account-attach-proof.v1"

    /// Server-chosen challenge length, in bytes.
    static let attachChallengeLength = 32

    /// 27 + 32 + 34.
    static let attachPreimageLength = attachProofDomain.utf8.count + attachChallengeLength + AccountID.rawLength

    /// Domain bytes then the canonical bytes.
    static func genesisProofPreimage(canonicalBytes: [UInt8]) -> [UInt8] {
        Array(genesisProofDomain.utf8) + canonicalBytes
    }

    /// Domain bytes, then the challenge, then the raw accountId bytes. Fixed length throughout.
    ///
    /// - Parameters:
    ///   - challenge: the 32 server-chosen bytes held against the login session
    ///   - accountID: the accountId this device registered; the server derives its own from the stored
    ///     genesis and reads none from the request, so a mismatch simply fails to verify
    static func attachProofPreimage(challenge: [UInt8], accountID: AccountID) throws -> [UInt8] {
        guard challenge.count == attachChallengeLength else { throw AccountGenesisError.wrongLength }
        return Array(attachProofDomain.utf8) + challenge + accountID.rawBytes
    }
}

// MARK: - Ed25519 point validation

/// Ed25519 public-key point decoding, which ADM-008 decision 1 requires a decoder to perform.
///
/// CryptoKit cannot stand in for this: `Curve25519.Signing.PublicKey(rawRepresentation:)` accepts any
/// 32 bytes, including a `y` larger than the field prime and a `y` that is on no curve point, and only
/// fails later at verification time. The golden vectors require both to be refused at decode, so the
/// decompression is done here.
///
/// Arithmetic is mod `p = 2^255 - 19` over four 64-bit limbs, little endian. It runs twice per genesis
/// decode, so it is written for clarity rather than speed, and it is never given secret input: these
/// are public keys.
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

        /// `sqrt(-1) mod p`.
        static let sqrtMinus1 = Field(limbs: [0xC4EE_1B27_4A0E_A0B0, 0x2F43_1806_AD2F_E478,
                                              0x2B4D_0099_3DFB_D7A7, 0x2B83_2480_4FC1_DF0B])

        /// `(p - 5) / 8`, little-endian bytes, the exponent of the candidate square root.
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
            // Fold the high half back in: 2^256 == 38 (mod p). The carry shrinks by orders of magnitude
            // each round, so this converges immediately; the bound is a belt-and-braces stop.
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

        /// Wrapping subtract, no modular correction. Only called when the result is known non-negative.
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

        /// Wrapping add, no modular correction.
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
