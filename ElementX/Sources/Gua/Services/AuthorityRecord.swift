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
    case unknownRevocationReason = "unknown_revocation_reason"
    case unknownAuthorization = "unknown_authorization"
    /// `authorization = 0x01` names no key. The committed-recovery path is authorized by a key, so a
    /// record claiming it and naming none is refused rather than read as the other path.
    case authorizingKeyRequired = "authorizing_key_required"
    /// `authorization = 0x02` names one. The pairing is enforced in both directions, so a record cannot
    /// claim the account-recovery path and carry a key whose signature a verifier might reach for.
    case authorizingKeyNotPermitted = "authorizing_key_not_permitted"
    case zeroOpposedRecord = "zero_opposed_record"

    var reason: String {
        rawValue
    }
}

/// The five record types of ADM-009 decision 2. The magic is the signature domain as well as the type
/// tag, which is what stops a record of one type being replayed as another.
enum AuthorityRecordType: String, Equatable, CaseIterable {
    case adoptRoot = "GUAA"
    case deviceGrant = "GUAD"
    case deviceRevoke = "GUAX"
    case authorityRecovery = "GUAR"
    /// Objects to the record it names. Revision 4 added it because revisions 1 to 3 asked an active
    /// device to oppose and gave it nothing to sign, so the server could only refuse the claim.
    case oppose = "GUAO"

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
        case .oppose: 144
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
/// All five types are built and validated here. The envelope is one builder for every type rather than
/// five, because a field offset that is written out per type is a field offset that drifts on the type
/// nobody looked at.
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

    /// Why a device was revoked. The reason is inside the signed bytes, so it is what a notification and
    /// a later log leaf can name, and an unknown value is refused rather than shown as "unspecified".
    static let reasonUnspecified: UInt8 = 0x01
    static let reasonLost: UInt8 = 0x02
    static let reasonReplaced: UInt8 = 0x03
    static let reasonCompromised: UInt8 = 0x04

    /// Authorized by the committed recovery authority key. Rank 2 of ADM-009 decision 3: the one record
    /// the owner can always land, and the one an intruder holding every device cannot cancel.
    static let authorizationRecoveryKey: UInt8 = 0x01
    /// Authorized through a completed account recovery. Rank 0, and vetoable by any active device.
    static let authorizationAccountRecovery: UInt8 = 0x02

    /// The 32 zero bytes the account-recovery path carries in place of an authorizing key.
    static let zeroKey = [UInt8](repeating: 0, count: keyLength)

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

    // DeviceRevoke body: deviceKey 32, reason 1, authorizingKey 32.
    private static let revokeDeviceKey = offsetBody
    private static let revokeReason = 112
    private static let revokeAuthorizingKey = 113

    // AuthorityRecovery body: deviceKey 32, recoveryAuthorityKey 32, label 16, entropy 16,
    // authorization 1, authorizingKey 32.
    private static let recoveryDeviceKey = offsetBody
    private static let recoveryRecoveryKey = 112
    private static let recoveryLabel = 144
    private static let recoveryEntropy = 160
    private static let recoveryAuthorization = 176
    private static let recoveryAuthorizingKey = 177

    // Oppose body: opposedRecordHash 32, authorizingKey 32.
    private static let opposeRecordHash = offsetBody
    private static let opposeAuthorizingKey = 112

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

    /// Canonical bytes of a `DeviceRevoke`.
    ///
    /// - Parameters:
    ///   - deviceKey: the key being removed. It may be this device's own, which takes effect at once
    ///     because a device giving up its own authority reduces what an attacker holding it could do.
    ///   - reason: one of the four ``reasonUnspecified`` through ``reasonCompromised``. It is inside the
    ///     signed bytes, so it is what a notification to the account's other devices may name.
    static func deviceRevoke(accountID: AccountID,
                             deviceKey: [UInt8],
                             reason: UInt8,
                             authorizingKey: [UInt8],
                             prevHash: [UInt8],
                             seq: UInt64) throws -> [UInt8] {
        guard deviceKey.count == keyLength, authorizingKey.count == keyLength else {
            throw AuthorityRecordError.wrongLength
        }
        var body = [UInt8]()
        body.append(contentsOf: deviceKey)
        body.append(reason)
        body.append(contentsOf: authorizingKey)
        return try envelope(type: .deviceRevoke,
                            accountID: accountID,
                            prevHash: prevHash,
                            seq: seq,
                            body: body)
    }

    /// Canonical bytes of an `AuthorityRecovery`, which replaces the device set with one device and
    /// installs a new recovery authority key in the same record.
    ///
    /// - Parameters:
    ///   - authorization: ``authorizationRecoveryKey`` or ``authorizationAccountRecovery``. The two are
    ///     not equal and the pairing with `authorizingKey` is a rule rather than a convention: under the
    ///     account-recovery path the field is all zero, and a decoder enforces that in both directions.
    ///   - authorizingKey: the committed recovery authority key under ``authorizationRecoveryKey``, and
    ///     ignored under ``authorizationAccountRecovery``, where 32 zero bytes are written instead.
    static func authorityRecovery(accountID: AccountID,
                                  deviceKey: [UInt8],
                                  recoveryKey: [UInt8],
                                  label: String,
                                  entropy: [UInt8],
                                  authorization: UInt8,
                                  authorizingKey: [UInt8],
                                  prevHash: [UInt8],
                                  seq: UInt64) throws -> [UInt8] {
        guard deviceKey.count == keyLength, recoveryKey.count == keyLength,
              entropy.count == entropyLength else {
            throw AuthorityRecordError.wrongLength
        }
        let named: [UInt8]
        switch authorization {
        case authorizationRecoveryKey:
            guard authorizingKey.count == keyLength else { throw AuthorityRecordError.wrongLength }
            named = authorizingKey
        case authorizationAccountRecovery:
            named = zeroKey
        default:
            throw AuthorityRecordError.unknownAuthorization
        }
        var body = [UInt8]()
        body.append(contentsOf: deviceKey)
        body.append(contentsOf: recoveryKey)
        body.append(contentsOf: AuthorityLabel.encode(label))
        body.append(contentsOf: entropy)
        body.append(authorization)
        body.append(contentsOf: named)
        return try envelope(type: .authorityRecovery,
                            accountID: accountID,
                            prevHash: prevHash,
                            seq: seq,
                            body: body)
    }

    /// Canonical bytes of an `Oppose`.
    ///
    /// It takes no slot and starts no window, so it carries the `seq` and `prevHash` of the record it
    /// cancels rather than the position after it: the chain never gets an `Oppose` appended to it.
    ///
    /// - Parameters:
    ///   - opposedRecordHash: the 32 raw bytes of the opposed record's hash, which the state response
    ///     reports as hex
    static func oppose(accountID: AccountID,
                       opposedRecordHash: [UInt8],
                       authorizingKey: [UInt8],
                       prevHash: [UInt8],
                       seq: UInt64) throws -> [UInt8] {
        guard opposedRecordHash.count == hashLength, authorizingKey.count == keyLength else {
            throw AuthorityRecordError.wrongLength
        }
        var body = [UInt8]()
        body.append(contentsOf: opposedRecordHash)
        body.append(contentsOf: authorizingKey)
        return try envelope(type: .oppose,
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

    /// Applies every rule identity-service's decoder applies, and refuses with the same token.
    ///
    /// The client checks its own bytes for the reason the genesis client does: the record is the
    /// authority, so bytes this app would refuse to read are bytes it must not ask a server to write.
    /// A record that fails here never leaves the device, and the failure names the rule rather than
    /// saying the request went wrong.
    static func validate(_ bytes: [UInt8]) throws {
        _ = try decode(bytes)
    }

    /// Validates `bytes` and reports what they say, keeping the bytes verbatim.
    ///
    /// Nothing re-encodes: the record hash is what the next record's `prevHash` must equal and what the
    /// log leaf of ADM-009 decision 12 will commit, so the bytes that are hashed have to be the bytes
    /// that crossed the wire.
    static func decode(_ bytes: [UInt8]) throws -> Decoded {
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

        let accountReference = Array(bytes[offsetAccount..<offsetPrevHash])
        let prevHash = Array(bytes[offsetPrevHash..<offsetSeq])

        switch type {
        case .adoptRoot:
            let deviceKey = try key(bytes, adoptDeviceKey, zero: .zeroDeviceKey, invalid: .invalidDeviceKey)
            guard bytes[adoptFramework] == recoveryFrameworkCommittedKey else {
                throw AuthorityRecordError.unknownRecoveryFramework
            }
            let recoveryKey = try key(bytes, adoptRecoveryKey, zero: .zeroRecoveryKey, invalid: .invalidRecoveryKey)
            guard deviceKey != recoveryKey else { throw AuthorityRecordError.duplicateKeys }
            try AuthorityLabel.validate(Array(bytes[adoptLabel..<adoptEntropy]))
            // The device key signs its own AdoptRoot: at seq 1 there is no other key the chain has.
            return Decoded(type: type, seq: seq, accountReference: accountReference, prevHash: prevHash,
                           deviceKey: deviceKey, verifyingKey: deviceKey, canonicalBytes: bytes)
        case .deviceGrant:
            let deviceKey = try key(bytes, grantDeviceKey, zero: .zeroDeviceKey, invalid: .invalidDeviceKey)
            guard bytes[grantFlags] == flagsNone else { throw AuthorityRecordError.unknownFlags }
            try AuthorityLabel.validate(Array(bytes[grantLabel..<grantAuthorizingKey]))
            let authorizingKey = try key(bytes, grantAuthorizingKey, zero: .zeroAuthorizingKey,
                                         invalid: .invalidAuthorizingKey)
            return Decoded(type: type, seq: seq, accountReference: accountReference, prevHash: prevHash,
                           deviceKey: deviceKey, verifyingKey: authorizingKey, canonicalBytes: bytes)
        case .deviceRevoke:
            let deviceKey = try key(bytes, revokeDeviceKey, zero: .zeroDeviceKey, invalid: .invalidDeviceKey)
            switch bytes[revokeReason] {
            case reasonUnspecified, reasonLost, reasonReplaced, reasonCompromised: break
            default: throw AuthorityRecordError.unknownRevocationReason
            }
            let authorizingKey = try key(bytes, revokeAuthorizingKey, zero: .zeroAuthorizingKey,
                                         invalid: .invalidAuthorizingKey)
            return Decoded(type: type, seq: seq, accountReference: accountReference, prevHash: prevHash,
                           deviceKey: deviceKey, verifyingKey: authorizingKey, canonicalBytes: bytes)
        case .authorityRecovery:
            let deviceKey = try key(bytes, recoveryDeviceKey, zero: .zeroDeviceKey, invalid: .invalidDeviceKey)
            let recoveryKey = try key(bytes, recoveryRecoveryKey, zero: .zeroRecoveryKey,
                                      invalid: .invalidRecoveryKey)
            guard deviceKey != recoveryKey else { throw AuthorityRecordError.duplicateKeys }
            try AuthorityLabel.validate(Array(bytes[recoveryLabel..<recoveryEntropy]))
            let named = Array(bytes[recoveryAuthorizingKey..<(recoveryAuthorizingKey + keyLength)])
            switch bytes[recoveryAuthorization] {
            case authorizationRecoveryKey:
                guard named.contains(where: { $0 != 0 }) else {
                    throw AuthorityRecordError.authorizingKeyRequired
                }
                let authorizingKey = try key(bytes, recoveryAuthorizingKey, zero: .zeroAuthorizingKey,
                                             invalid: .invalidAuthorizingKey)
                return Decoded(type: type, seq: seq, accountReference: accountReference, prevHash: prevHash,
                               deviceKey: deviceKey, verifyingKey: authorizingKey, canonicalBytes: bytes)
            case authorizationAccountRecovery:
                // The pairing is enforced the other way too. A record claiming the weaker path while
                // naming a key would give a verifier two keys to choose between, and the point of the
                // field is that a log leaf commits which one authorized the transition.
                guard !named.contains(where: { $0 != 0 }) else {
                    throw AuthorityRecordError.authorizingKeyNotPermitted
                }
                // Under this path the record is signed by the device key it installs: the account has no
                // other key left, which is the situation the path exists for.
                return Decoded(type: type, seq: seq, accountReference: accountReference, prevHash: prevHash,
                               deviceKey: deviceKey, verifyingKey: deviceKey, canonicalBytes: bytes)
            default:
                throw AuthorityRecordError.unknownAuthorization
            }
        case .oppose:
            let opposed = Array(bytes[opposeRecordHash..<(opposeRecordHash + hashLength)])
            guard opposed.contains(where: { $0 != 0 }) else {
                throw AuthorityRecordError.zeroOpposedRecord
            }
            let authorizingKey = try key(bytes, opposeAuthorizingKey, zero: .zeroAuthorizingKey,
                                         invalid: .invalidAuthorizingKey)
            return Decoded(type: type, seq: seq, accountReference: accountReference, prevHash: prevHash,
                           deviceKey: nil, verifyingKey: authorizingKey, canonicalBytes: bytes)
        }
    }

    /// What one record says, as this client reads it back.
    ///
    /// `verifyingKey` is the key the type names as its signer, which is not one field: an `AdoptRoot` is
    /// signed by the device key it carries, a grant, a revocation and an `Oppose` by their
    /// `authorizingKey`, and an `AuthorityRecovery` by its `authorizingKey` except on the account-recovery
    /// path, where that field is zero by rule and the signer is the device key being installed.
    struct Decoded: Equatable {
        let type: AuthorityRecordType
        let seq: UInt64
        let accountReference: [UInt8]
        let prevHash: [UInt8]
        let deviceKey: [UInt8]?
        let verifyingKey: [UInt8]
        let canonicalBytes: [UInt8]
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

/// The short human fingerprint of a device authority key (ADM-009 decision 5, revision 4).
///
/// It is the only thing crossing between two phones that a person has to compare, so the alphabet and the
/// length are stated here rather than left to whichever screen shows it. Eight characters, from the
/// 31-character alphabet `ABCDEFGHJKLMNPQRSTUVWXYZ2346789`, which leaves out I, O, 0, 1 and 5: a
/// fingerprint two people read aloud across a room fails at exactly the characters that look alike. The
/// alphabet is copied from identity-service character for character rather than from its prose, which
/// says S is left out as well while the constant keeps it.
///
/// **Derived, never issued.** Both devices compute the same eight characters from the same 32 public
/// bytes, so the comparison means the two phones are looking at one key. A server-issued nonce would mean
/// only that both had spoken to the same server, which is the property already assumed and not the one
/// being checked. That also makes this the check: the granting phone recomputes the fingerprint from the
/// candidate's key rather than trusting the string the server sent beside it.
enum AuthorityFingerprint {
    /// No I, O, 0, 1, 5 or S. A fingerprint gets read aloud.
    static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ2346789")

    /// Eight characters, shown in two groups of four.
    static let length = 8

    private static let domain = "gua-authority-candidate.v1"

    /// The fingerprint of one raw Ed25519 device key, or `nil` when the key is not 32 bytes.
    ///
    /// Domain-separated, so the same bytes used for something else never produce the same string, and
    /// taken from the front of the digest rather than from the key itself: a fingerprint that showed key
    /// bytes would make two keys with a shared prefix look identical.
    static func of(_ rawDeviceKey: [UInt8]) -> String? {
        guard rawDeviceKey.count == AuthorityRecord.keyLength else { return nil }
        var digest = SHA256()
        digest.update(data: Data(domain.utf8))
        digest.update(data: Data(rawDeviceKey))
        let bytes = [UInt8](digest.finalize())
        return String(bytes.prefix(length).map { alphabet[Int($0) % alphabet.count] })
    }

    /// The same eight characters in the two groups of four the screens show.
    static func grouped(_ fingerprint: String) -> String {
        guard fingerprint.count == length else { return fingerprint }
        let middle = fingerprint.index(fingerprint.startIndex, offsetBy: length / 2)
        return "\(fingerprint[fingerprint.startIndex..<middle]) \(fingerprint[middle...])"
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

    /// The domain an install signs to bind its security-notification registration to a device key.
    static let notificationDomain = "gua-authority-notification.v1"

    /// 29 + 34 + 32 + 32 + 32.
    static let notificationPreimageLength = notificationDomain.utf8.count
        + AuthorityRecord.accountReferenceLength
        + AuthorityRecord.hashLength
        + AuthorityRecord.keyLength
        + AuthorityRecord.challengeLength

    /// The preimage an install signs to bind its security-notification registration to a device authority
    /// key (ADM-009 gate 2, the removal tiers).
    ///
    /// Why it has to be signed rather than asserted. A registration that carries a device key needs a
    /// signature by that key before it may be removed from another install, so the key on the row is the
    /// thing standing between an attacker with a fresh post-recovery session and a silent channel. If the
    /// field could simply be claimed, an attacker would name the owner's key on their own row, and, worse,
    /// a row could be planted that the owner's own device can never remove.
    ///
    /// The installation id is hashed rather than carried, so every element is fixed length and no field
    /// can be shifted into another. ADM-009 does not define this preimage: it is the wire addition gate
    /// 2's own removal tiers need, and identity-service states it in `AuthorityProofs` so both clients
    /// sign the same bytes.
    static func notificationPreimage(accountID: AccountID,
                                     installationID: String,
                                     deviceKey: [UInt8],
                                     challenge: [UInt8]) throws -> [UInt8] {
        guard deviceKey.count == AuthorityRecord.keyLength,
              challenge.count == AuthorityRecord.challengeLength else {
            throw AuthorityRecordError.wrongLength
        }
        let installationIDHash = [UInt8](SHA256.hash(data: Data(installationID.utf8)))
        return Array(notificationDomain.utf8) + accountID.rawBytes + installationIDHash + deviceKey + challenge
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
