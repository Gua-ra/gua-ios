//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import CryptoKit
import Foundation

/// Why a set of canonical authority-record bytes was refused.
///
/// The raw values are identity-service's own `InvalidAuthorityRecordException.reason()` tokens, so a
/// record this client refuses to send and a record the server refuses to accept are named the same way.
/// The server returns them under `invalid_authority_record`, and a client that spelled them differently
/// would make the two halves impossible to compare.
enum AuthorityRecordError: String, Error, Equatable {
    case wrongLength = "wrong_length"
    case badMagic = "bad_magic"
    case unknownVersion = "unknown_version"
    case unknownSuite = "unknown_suite"
    case unknownRecoveryFramework = "unknown_recovery_framework"
    case unknownFlags = "unknown_flags"
    case badSeq = "bad_seq"
    case zeroDeviceKey = "zero_device_key"
    case zeroRecoveryKey = "zero_recovery_key"
    case zeroAuthorizingKey = "zero_authorizing_key"
    case invalidDeviceKey = "invalid_device_key"
    case invalidRecoveryKey = "invalid_recovery_key"
    case invalidAuthorizingKey = "invalid_authorizing_key"
    case duplicateKeys = "duplicate_keys"
    case nonCanonicalLabel = "non_canonical_label"

    var reason: String {
        rawValue
    }
}

/// The four record types of ADM-009 decision 2. The magic is the signature domain as well as the type
/// tag, which is what stops a record of one type being replayed as another.
enum AuthorityRecordType: String, Equatable, CaseIterable {
    case adoptRoot = "GUAA"
    case deviceGrant = "GUAD"
    case deviceRevoke = "GUAX"
    case authorityRecovery = "GUAR"

    var magic: [UInt8] {
        Array(rawValue.utf8)
    }

    /// Total canonical length, envelope included. Any other length is refused.
    var length: Int {
        switch self {
        case .adoptRoot: 177
        case .deviceGrant: 161
        case .deviceRevoke: 145
        case .authorityRecovery: 209
        }
    }
}

/// The one envelope every authority record shares, and the two bodies this client writes.
///
/// ```
/// off len field
/// 0   4   magic, ASCII, one per record type, and the signature domain
/// 4   1   version = 0x01
/// 5   1   suite = 0x01 (Ed25519 with SHA-256)
/// 6   34  accountId raw bytes, exactly what AccountID.rawBytes holds
/// 40  32  prevHash, SHA-256 over the previous record's canonical bytes, or 32 zeros in the first
/// 72  8   seq, unsigned big-endian, 1 in the first record
/// 80  ..  body, fixed per type
/// ```
///
/// Fixed layout, big-endian, no delimiters, canonical under ADM-001 L4. Nothing here is optional and
/// nothing is length-prefixed, so no field can be shifted into another.
///
/// **Only `AdoptRoot` and `DeviceGrant` are built here**, because they are the only two records this app
/// can honestly produce today: a revocation and an authority recovery have no surface in this build
/// (see the ADM-009 notes in ``AccountAuthorityService``). The envelope and the validator are written
/// for all four so the missing halves are a missing screen rather than a missing codec.
enum AuthorityRecord {
    static let version: UInt8 = 0x01
    /// Ed25519 authority keys, SHA-256 hashing.
    static let suiteEd25519SHA256: UInt8 = 0x01

    static let magicLength = 4
    static let accountReferenceLength = AccountID.rawLength
    static let hashLength = 32
    static let keyLength = 32
    static let labelLength = 16
    static let entropyLength = 16
    static let challengeLength = 32
    static let signatureLength = 64
    static let envelopeLength = 80

    /// One committed recovery authority key, the only framework ADM-008 decision 4 accepts.
    static let recoveryFrameworkCommittedKey: UInt8 = 0x01
    /// No grant flag is defined. A decoder refuses a reserved bit rather than ignoring it.
    static let flagsNone: UInt8 = 0x00

    private static let offsetVersion = 4
    private static let offsetSuite = 5
    private static let offsetAccount = 6
    private static let offsetPrevHash = 40
    private static let offsetSeq = 72
    private static let offsetBody = 80

    // AdoptRoot body: deviceKey 32, recoveryFrameworkId 1, recoveryAuthorityKey 32, label 16, entropy 16.
    private static let adoptDeviceKey = offsetBody
    private static let adoptFramework = 112
    private static let adoptRecoveryKey = 113
    private static let adoptLabel = 145
    private static let adoptEntropy = 161

    // DeviceGrant body: deviceKey 32, flags 1, label 16, authorizingKey 32.
    private static let grantDeviceKey = offsetBody
    private static let grantFlags = 112
    private static let grantLabel = 113
    private static let grantAuthorizingKey = 129

    /// 32 zero bytes: the `prevHash` of a chain's first record.
    static let emptyPrevHash = [UInt8](repeating: 0, count: hashLength)

    /// Canonical bytes of an `AdoptRoot` at `seq = 1`.
    ///
    /// - Parameters:
    ///   - accountID: the account's own id, read from `GET /account/authority`, which is the one
    ///     endpoint that returns it to its holder. The server rebuilds these 34 bytes from its own
    ///     session state and reads none from the request, so a wrong id simply fails to verify.
    ///   - deviceKey: the public half of the device authority key generated on this device
    ///   - recoveryKey: the public half of the recovery authority key, which must differ from it
    static func adoptRoot(accountID: AccountID,
                          deviceKey: [UInt8],
                          recoveryKey: [UInt8],
                          label: String,
                          entropy: [UInt8]) throws -> [UInt8] {
        guard deviceKey.count == keyLength, recoveryKey.count == keyLength, entropy.count == entropyLength else {
            throw AuthorityRecordError.wrongLength
        }
        var body = [UInt8]()
        body.append(contentsOf: deviceKey)
        body.append(recoveryFrameworkCommittedKey)
        body.append(contentsOf: recoveryKey)
        body.append(contentsOf: AuthorityLabel.encode(label))
        body.append(contentsOf: entropy)
        return try envelope(type: .adoptRoot,
                            accountID: accountID,
                            prevHash: emptyPrevHash,
                            seq: 1,
                            body: body)
    }

    /// Canonical bytes of a `DeviceGrant`.
    ///
    /// - Parameters:
    ///   - granteeKey: the public key the new device generated for itself. It never receives this
    ///     device's key: copying one key to every device is what makes a revocation meaningless.
    ///   - authorizingKey: the key whose signature authorizes this record, inside the bytes that are
    ///     hashed, so a later log leaf commits who authorized the transition and not only that
    ///     somebody did. The server checks it equals the verifying key rather than inferring it.
    static func deviceGrant(accountID: AccountID,
                            granteeKey: [UInt8],
                            label: String,
                            authorizingKey: [UInt8],
                            prevHash: [UInt8],
                            seq: UInt64) throws -> [UInt8] {
        guard granteeKey.count == keyLength, authorizingKey.count == keyLength else {
            throw AuthorityRecordError.wrongLength
        }
        var body = [UInt8]()
        body.append(contentsOf: granteeKey)
        body.append(flagsNone)
        body.append(contentsOf: AuthorityLabel.encode(label))
        body.append(contentsOf: authorizingKey)
        return try envelope(type: .deviceGrant,
                            accountID: accountID,
                            prevHash: prevHash,
                            seq: seq,
                            body: body)
    }

    /// The envelope around one body.
    static func envelope(type: AuthorityRecordType,
                         accountID: AccountID,
                         prevHash: [UInt8],
                         seq: UInt64,
                         body: [UInt8]) throws -> [UInt8] {
        guard prevHash.count == hashLength,
              body.count == type.length - envelopeLength,
              accountID.rawBytes.count == accountReferenceLength else {
            throw AuthorityRecordError.wrongLength
        }
        guard seq >= 1 else { throw AuthorityRecordError.badSeq }

        var out = [UInt8]()
        out.reserveCapacity(type.length)
        out.append(contentsOf: type.magic)
        out.append(version)
        out.append(suiteEd25519SHA256)
        out.append(contentsOf: accountID.rawBytes)
        out.append(contentsOf: prevHash)
        for shift in stride(from: 56, through: 0, by: -8) {
            out.append(UInt8((seq >> UInt64(shift)) & 0xFF))
        }
        out.append(contentsOf: body)
        return out
    }

    /// Applies every rule identity-service's decoder applies to the two record types this client
    /// builds, and refuses with the same token.
    ///
    /// The client checks its own bytes for the reason the genesis client does: the record is the
    /// authority, so bytes this app would refuse to read are bytes it must not ask a server to write.
    /// A record that fails here never leaves the device, and the failure names the rule rather than
    /// saying the request went wrong.
    static func validate(_ bytes: [UInt8]) throws {
        guard bytes.count >= magicLength else { throw AuthorityRecordError.wrongLength }
        let magic = Array(bytes[0..<magicLength])
        guard let type = AuthorityRecordType.allCases.first(where: { $0.magic == magic }) else {
            throw AuthorityRecordError.badMagic
        }
        guard bytes.count == type.length else { throw AuthorityRecordError.wrongLength }
        guard bytes[offsetVersion] == version else { throw AuthorityRecordError.unknownVersion }
        guard bytes[offsetSuite] == suiteEd25519SHA256 else { throw AuthorityRecordError.unknownSuite }

        var seq: UInt64 = 0
        for index in offsetSeq..<(offsetSeq + 8) {
            seq = (seq << 8) | UInt64(bytes[index])
        }
        // seq counts from 1, and an unsigned field a server would read as a negative long is the same
        // defect, which is why the top bit is refused here rather than only the zero.
        guard seq >= 1, seq <= UInt64(Int64.max) else { throw AuthorityRecordError.badSeq }

        switch type {
        case .adoptRoot:
            let deviceKey = try key(bytes, adoptDeviceKey, zero: .zeroDeviceKey, invalid: .invalidDeviceKey)
            guard bytes[adoptFramework] == recoveryFrameworkCommittedKey else {
                throw AuthorityRecordError.unknownRecoveryFramework
            }
            let recoveryKey = try key(bytes, adoptRecoveryKey, zero: .zeroRecoveryKey, invalid: .invalidRecoveryKey)
            guard deviceKey != recoveryKey else { throw AuthorityRecordError.duplicateKeys }
            try AuthorityLabel.validate(Array(bytes[adoptLabel..<adoptEntropy]))
        case .deviceGrant:
            _ = try key(bytes, grantDeviceKey, zero: .zeroDeviceKey, invalid: .invalidDeviceKey)
            guard bytes[grantFlags] == flagsNone else { throw AuthorityRecordError.unknownFlags }
            try AuthorityLabel.validate(Array(bytes[grantLabel..<grantAuthorizingKey]))
            _ = try key(bytes, grantAuthorizingKey, zero: .zeroAuthorizingKey, invalid: .invalidAuthorizingKey)
        case .deviceRevoke, .authorityRecovery:
            // This build writes neither, so there is nothing here whose rules it could claim to hold.
            // Validating them loosely would be worse than not validating them: it would read as
            // coverage that is not there.
            throw AuthorityRecordError.badMagic
        }
    }

    /// SHA-256 over canonical bytes, lowercase hex, which is how identity-service names a record.
    static func hash(_ canonicalBytes: [UInt8]) -> String {
        SHA256.hash(data: Data(canonicalBytes)).map { String(format: "%02x", $0) }.joined()
    }

    /// The 32 raw bytes behind a hex record hash, which is what a `prevHash` field holds.
    static func hashBytes(fromHex hex: String) -> [UInt8]? {
        guard hex.count == hashLength * 2 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(hashLength)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }

    /// An Ed25519 key at `offset`, refused when it is all zero and again when it is not a curve point.
    ///
    /// Two rules rather than one, because the all-zero encoding decodes to a valid low-order point, so
    /// point decoding alone lets it through. ADM-008 decision 1 lists them separately and so does the
    /// server's decoder.
    private static func key(_ bytes: [UInt8],
                            _ offset: Int,
                            zero: AuthorityRecordError,
                            invalid: AuthorityRecordError) throws -> [UInt8] {
        let raw = Array(bytes[offset..<(offset + keyLength)])
        guard raw.contains(where: { $0 != 0 }) else { throw zero }
        guard Ed25519PublicKeyValidator.isValid(raw) else { throw invalid }
        return raw
    }
}

/// A 16-byte device label: UTF-8, zero-padded to its end.
///
/// A label is what a notification about a pending transition is allowed to name, which is the whole
/// reason it is in the record at all. One label has one encoding: a non-zero byte after the first zero
/// is refused, so a notification cannot be made to name something the padding hid.
enum AuthorityLabel {
    static let length = AuthorityRecord.labelLength

    /// Pads or truncates `value` to 16 bytes.
    ///
    /// Truncation is on a character boundary rather than a byte one, so a label ending in an accented
    /// letter or an emoji is cut short instead of ending in half a scalar the server would decode as a
    /// replacement character.
    static func encode(_ value: String) -> [UInt8] {
        var out = [UInt8]()
        for character in value {
            let bytes = Array(String(character).utf8)
            guard out.count + bytes.count <= length else { break }
            out.append(contentsOf: bytes)
        }
        // A label whose first byte is zero is an empty label, which is permitted: the server's rule is
        // about what follows the first zero, not about there being one.
        return out + [UInt8](repeating: 0, count: length - out.count)
    }

    static func decode(_ raw: [UInt8]) -> String {
        let end = raw.firstIndex(of: 0) ?? raw.count
        return String(decoding: raw[0..<end], as: UTF8.self)
    }

    static func validate(_ raw: [UInt8]) throws {
        guard raw.count == length else { throw AuthorityRecordError.wrongLength }
        let end = raw.firstIndex(of: 0) ?? raw.count
        guard raw[end...].allSatisfy({ $0 == 0 }) else { throw AuthorityRecordError.nonCanonicalLabel }
    }
}

/// The one preimage rule of the authority chain, and the browser-approval preimage beside it (ADM-009
/// decisions 2 and 6).
///
/// **One preimage, for every type**: `magic || the 32 challenge bytes || the canonical bytes`. Three
/// properties follow and all three are needed. The magic is the signature domain, so no record can be
/// replayed as another type. The accountId is inside the canonical bytes, so none can be replayed into
/// another account. And the challenge is inside every signature, so no record is precomputable on other
/// hardware, transferable to another party, or resubmittable after it was opposed.
///
/// It is deliberately the same shape as ``GenesisProofs``: a domain, then the server's bytes, then the
/// object's bytes, each fixed length. One builder used by every type is what keeps the rule from going
/// missing on the type nobody looked at.
enum AuthorityProofs {
    /// The domain a device signs when it approves an action a browser session started.
    static let approvalDomain = "gua-authority-approval.v1"

    /// Bytes of a pending-approval id inside the preimage. The id crosses the wire as base64url of
    /// exactly these 16 bytes.
    static let approvalIDLength = 16

    /// 25 + 34 + 16 + 32 + 32.
    static let approvalPreimageLength = approvalDomain.utf8.count
        + AuthorityRecord.accountReferenceLength
        + approvalIDLength
        + AuthorityRecord.hashLength
        + AuthorityRecord.challengeLength

    /// The preimage a record is signed over.
    static func recordPreimage(type: AuthorityRecordType,
                               challenge: [UInt8],
                               canonicalBytes: [UInt8]) throws -> [UInt8] {
        guard challenge.count == AuthorityRecord.challengeLength,
              canonicalBytes.count == type.length else {
            throw AuthorityRecordError.wrongLength
        }
        return type.magic + challenge + canonicalBytes
    }

    /// The preimage an authority device signs to approve an action reached from a browser: the domain,
    /// the accountId bytes, the approval id, the action digest and the challenge.
    ///
    /// Every element is fixed length, so no field can be shifted into another. The action digest is what
    /// makes the approval specific: a malicious page can start an approval the user never wanted, and
    /// what defends that is the four-character code plus a device-side description of this exact digest,
    /// on a screen the page does not control.
    static func approvalPreimage(accountID: AccountID,
                                 approvalID: [UInt8],
                                 actionDigest: [UInt8],
                                 challenge: [UInt8]) throws -> [UInt8] {
        guard approvalID.count == approvalIDLength,
              actionDigest.count == AuthorityRecord.hashLength,
              challenge.count == AuthorityRecord.challengeLength else {
            throw AuthorityRecordError.wrongLength
        }
        return Array(approvalDomain.utf8) + accountID.rawBytes + approvalID + actionDigest + challenge
    }
}
