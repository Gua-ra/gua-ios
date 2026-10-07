//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import CryptoKit
import Foundation

/// Raw values are identity-service's refusal tokens.
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
    case authorizingKeyRequired = "authorizing_key_required"
    case authorizingKeyNotPermitted = "authorizing_key_not_permitted"
    case zeroOpposedRecord = "zero_opposed_record"

    var reason: String {
        rawValue
    }
}

/// The magic is both the type tag and the signature domain.
enum AuthorityRecordType: String, Equatable, CaseIterable {
    case adoptRoot = "GUAA"
    case deviceGrant = "GUAD"
    case deviceRevoke = "GUAX"
    case authorityRecovery = "GUAR"
    case oppose = "GUAO"

    var magic: [UInt8] {
        Array(rawValue.utf8)
    }

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

/// Canonical fixed-width encoding. Signatures cover these exact bytes.
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
enum AuthorityRecord {
    static let version: UInt8 = 0x01
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

    static let recoveryFrameworkCommittedKey: UInt8 = 0x01
    static let flagsNone: UInt8 = 0x00

    static let reasonUnspecified: UInt8 = 0x01
    static let reasonLost: UInt8 = 0x02
    static let reasonReplaced: UInt8 = 0x03
    static let reasonCompromised: UInt8 = 0x04

    static let authorizationRecoveryKey: UInt8 = 0x01
    static let authorizationAccountRecovery: UInt8 = 0x02

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

    static let emptyPrevHash = [UInt8](repeating: 0, count: hashLength)

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

    /// Carries the `seq` and `prevHash` of the record it opposes, not the position after it.
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

    static func validate(_ bytes: [UInt8]) throws {
        _ = try decode(bytes)
    }

    // swiftlint:disable cyclomatic_complexity

    /// Keeps the bytes verbatim: the record hash covers the bytes that crossed the wire.
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
        // The server reads seq as a signed 64-bit integer.
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
                guard !named.contains(where: { $0 != 0 }) else {
                    throw AuthorityRecordError.authorizingKeyNotPermitted
                }
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

    // swiftlint:enable cyclomatic_complexity

    /// `verifyingKey` is the device key for `AdoptRoot` and for an account-recovery `AuthorityRecovery`, otherwise `authorizingKey`.
    struct Decoded: Equatable {
        let type: AuthorityRecordType
        let seq: UInt64
        let accountReference: [UInt8]
        let prevHash: [UInt8]
        let deviceKey: [UInt8]?
        let verifyingKey: [UInt8]
        let canonicalBytes: [UInt8]
    }

    static func hash(_ canonicalBytes: [UInt8]) -> String {
        SHA256.hash(data: Data(canonicalBytes)).map { String(format: "%02x", $0) }.joined()
    }

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

    /// The all-zero key is refused separately because it decodes as a valid low-order point.
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

enum AuthorityLabel {
    static let length = AuthorityRecord.labelLength

    static func encode(_ value: String) -> [UInt8] {
        var out = [UInt8]()
        for character in value {
            let bytes = Array(String(character).utf8)
            guard out.count + bytes.count <= length else { break }
            out.append(contentsOf: bytes)
        }
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

/// Computed from the key on both devices, never issued by the server.
enum AuthorityFingerprint {
    /// Must match identity-service's alphabet exactly.
    static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ2346789")

    static let length = 8

    private static let domain = "gua-authority-candidate.v1"

    static func of(_ rawDeviceKey: [UInt8]) -> String? {
        guard rawDeviceKey.count == AuthorityRecord.keyLength else { return nil }
        var digest = SHA256()
        digest.update(data: Data(domain.utf8))
        digest.update(data: Data(rawDeviceKey))
        let bytes = [UInt8](digest.finalize())
        return String(bytes.prefix(length).map { alphabet[Int($0) % alphabet.count] })
    }

    static func grouped(_ fingerprint: String) -> String {
        guard fingerprint.count == length else { return fingerprint }
        let middle = fingerprint.index(fingerprint.startIndex, offsetBy: length / 2)
        return "\(fingerprint[fingerprint.startIndex..<middle]) \(fingerprint[middle...])"
    }
}

/// Record preimage: magic, then the 32 challenge bytes, then the canonical bytes, for every type.
enum AuthorityProofs {
    static let approvalDomain = "gua-authority-approval.v1"

    static let approvalIDLength = 16

    static let approvalPreimageLength = approvalDomain.utf8.count
        + AuthorityRecord.accountReferenceLength
        + approvalIDLength
        + AuthorityRecord.hashLength
        + AuthorityRecord.challengeLength

    static func recordPreimage(type: AuthorityRecordType,
                               challenge: [UInt8],
                               canonicalBytes: [UInt8]) throws -> [UInt8] {
        guard challenge.count == AuthorityRecord.challengeLength,
              canonicalBytes.count == type.length else {
            throw AuthorityRecordError.wrongLength
        }
        return type.magic + challenge + canonicalBytes
    }

    static let notificationDomain = "gua-authority-notification.v1"

    static let notificationPreimageLength = notificationDomain.utf8.count
        + AuthorityRecord.accountReferenceLength
        + AuthorityRecord.hashLength
        + AuthorityRecord.keyLength
        + AuthorityRecord.challengeLength

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
