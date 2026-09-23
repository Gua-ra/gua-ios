//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import CryptoKit
@testable import ElementX
import XCTest

/// The codec and the preimage rule of ADM-009 decisions 2 and 6.
///
/// The offsets, lengths and refusal tokens here are identity-service's, so a disagreement between the two
/// halves shows up as a failing test on this side rather than as a 400 in dev.
final class AuthorityRecordTests: XCTestCase {
    private var accountID: AccountID!
    private var deviceKey: [UInt8]!
    private var recoveryKey: [UInt8]!
    private let entropy = [UInt8](repeating: 0x2A, count: AuthorityRecord.entropyLength)
    private let challenge = [UInt8](repeating: 0x07, count: AuthorityRecord.challengeLength)

    override func setUpWithError() throws {
        accountID = try AccountID.derive(rootClass: AccountID.classBootstrap,
                                         canonicalBytes: [UInt8]("bootstrap-account-under-test".utf8))
        deviceKey = [UInt8](Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        recoveryKey = [UInt8](Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
    }

    // MARK: - The envelope

    func testAdoptRootIsTheLengthAndLayoutTheServerDecodes() throws {
        let bytes = try AuthorityRecord.adoptRoot(accountID: accountID,
                                                  deviceKey: deviceKey,
                                                  recoveryKey: recoveryKey,
                                                  label: "iPhone",
                                                  entropy: entropy)

        XCTAssertEqual(bytes.count, 177)
        XCTAssertEqual(Array(bytes[0..<4]), Array("GUAA".utf8))
        XCTAssertEqual(bytes[4], AuthorityRecord.version)
        XCTAssertEqual(bytes[5], AuthorityRecord.suiteEd25519SHA256)
        XCTAssertEqual(Array(bytes[6..<40]), accountID.rawBytes)
        XCTAssertEqual(Array(bytes[40..<72]), AuthorityRecord.emptyPrevHash, "A chain's first record has no previous one.")
        XCTAssertEqual(Array(bytes[72..<80]), [0, 0, 0, 0, 0, 0, 0, 1], "seq is unsigned big-endian and starts at 1.")
        XCTAssertEqual(Array(bytes[80..<112]), deviceKey)
        XCTAssertEqual(bytes[112], AuthorityRecord.recoveryFrameworkCommittedKey)
        XCTAssertEqual(Array(bytes[113..<145]), recoveryKey)
        XCTAssertEqual(AuthorityLabel.decode(Array(bytes[145..<161])), "iPhone")
        XCTAssertEqual(Array(bytes[161..<177]), entropy)
    }

    func testDeviceGrantIsTheLengthAndLayoutTheServerDecodes() throws {
        let granteeKey = [UInt8](Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        let prevHash = [UInt8](repeating: 0x11, count: 32)

        let bytes = try AuthorityRecord.deviceGrant(accountID: accountID,
                                                    granteeKey: granteeKey,
                                                    label: "iPad",
                                                    authorizingKey: deviceKey,
                                                    prevHash: prevHash,
                                                    seq: 258)

        XCTAssertEqual(bytes.count, 161)
        XCTAssertEqual(Array(bytes[0..<4]), Array("GUAD".utf8))
        XCTAssertEqual(Array(bytes[40..<72]), prevHash)
        XCTAssertEqual(Array(bytes[72..<80]), [0, 0, 0, 0, 0, 0, 1, 2])
        XCTAssertEqual(Array(bytes[80..<112]), granteeKey)
        XCTAssertEqual(bytes[112], AuthorityRecord.flagsNone)
        XCTAssertEqual(AuthorityLabel.decode(Array(bytes[113..<129])), "iPad")
        // authorizingKey names the key that authorizes the record, inside the bytes that are hashed, so a
        // log leaf commits who authorized the transition and not only that somebody did.
        XCTAssertEqual(Array(bytes[129..<161]), deviceKey)
    }

    func testTheKeysAGrantNamesAreTheGranteesAndTheSigners() throws {
        // The new device generates its own key and never receives another device's: a per-device key is
        // what gives a revocation an effect at all.
        let granteeKey = [UInt8](Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        let bytes = try AuthorityRecord.deviceGrant(accountID: accountID,
                                                    granteeKey: granteeKey,
                                                    label: "iPad",
                                                    authorizingKey: deviceKey,
                                                    prevHash: AuthorityRecord.emptyPrevHash,
                                                    seq: 2)

        XCTAssertNotEqual(Array(bytes[80..<112]), Array(bytes[129..<161]))
    }

    // MARK: - Refusals

    func testARecordWithTwoEqualKeysIsRefused() throws {
        // The server refuses it with `duplicate_keys`, and a record this client would not read is one it
        // must not ask a server to write.
        let bytes = try AuthorityRecord.adoptRoot(accountID: accountID,
                                                  deviceKey: deviceKey,
                                                  recoveryKey: deviceKey,
                                                  label: "iPhone",
                                                  entropy: entropy)
        assertRefused(bytes, with: .duplicateKeys)
    }

    func testAnAllZeroKeyIsRefusedSeparatelyFromPointDecoding() throws {
        var bytes = try AuthorityRecord.adoptRoot(accountID: accountID,
                                                  deviceKey: deviceKey,
                                                  recoveryKey: recoveryKey,
                                                  label: "iPhone",
                                                  entropy: entropy)
        // The all-zero encoding decodes to a valid low-order point, so point decoding alone lets it
        // through. That is why the rule is its own.
        bytes.replaceSubrange(80..<112, with: [UInt8](repeating: 0, count: 32))
        assertRefused(bytes, with: .zeroDeviceKey)
    }

    func testAKeyThatIsNotOnTheCurveIsRefused() throws {
        var bytes = try AuthorityRecord.adoptRoot(accountID: accountID,
                                                  deviceKey: deviceKey,
                                                  recoveryKey: recoveryKey,
                                                  label: "iPhone",
                                                  entropy: entropy)
        // y = p - 1 with every other bit set: above the field prime, so no point decodes from it.
        bytes.replaceSubrange(80..<112, with: [UInt8](repeating: 0xFF, count: 32))
        assertRefused(bytes, with: .invalidDeviceKey)
    }

    func testALabelWithAByteAfterItsFirstZeroIsRefused() throws {
        var bytes = try AuthorityRecord.adoptRoot(accountID: accountID,
                                                  deviceKey: deviceKey,
                                                  recoveryKey: recoveryKey,
                                                  label: "iPhone",
                                                  entropy: entropy)
        // One label, one encoding: otherwise a notification can be made to name something the padding
        // hid.
        bytes[160] = 0x41
        assertRefused(bytes, with: .nonCanonicalLabel)
    }

    func testAnUnknownMagicVersionSuiteOrFlagIsRefused() throws {
        let adopt = try AuthorityRecord.adoptRoot(accountID: accountID,
                                                  deviceKey: deviceKey,
                                                  recoveryKey: recoveryKey,
                                                  label: "iPhone",
                                                  entropy: entropy)
        var wrongMagic = adopt
        wrongMagic.replaceSubrange(0..<4, with: Array("GUAZ".utf8))
        assertRefused(wrongMagic, with: .badMagic)

        var wrongVersion = adopt
        wrongVersion[4] = 0x02
        assertRefused(wrongVersion, with: .unknownVersion)

        var wrongSuite = adopt
        wrongSuite[5] = 0x02
        assertRefused(wrongSuite, with: .unknownSuite)

        var wrongFramework = adopt
        wrongFramework[112] = 0x02
        assertRefused(wrongFramework, with: .unknownRecoveryFramework)

        var grant = try AuthorityRecord.deviceGrant(accountID: accountID,
                                                    granteeKey: recoveryKey,
                                                    label: "iPad",
                                                    authorizingKey: deviceKey,
                                                    prevHash: AuthorityRecord.emptyPrevHash,
                                                    seq: 2)
        // A reserved bit is refused rather than ignored: a decoder that drops a bit it does not
        // understand accepts a record whose meaning it cannot state.
        grant[112] = 0x01
        assertRefused(grant, with: .unknownFlags)
    }

    func testASeqBelowOneIsRefused() throws {
        var bytes = try AuthorityRecord.adoptRoot(accountID: accountID,
                                                  deviceKey: deviceKey,
                                                  recoveryKey: recoveryKey,
                                                  label: "iPhone",
                                                  entropy: entropy)
        bytes.replaceSubrange(72..<80, with: [UInt8](repeating: 0, count: 8))
        assertRefused(bytes, with: .badSeq)
    }

    func testAWrongLengthIsRefused() throws {
        let bytes = try AuthorityRecord.adoptRoot(accountID: accountID,
                                                  deviceKey: deviceKey,
                                                  recoveryKey: recoveryKey,
                                                  label: "iPhone",
                                                  entropy: entropy)
        assertRefused(Array(bytes.dropLast()), with: .wrongLength)
    }

    // MARK: - Labels

    func testALabelIsPaddedTruncatedOnACharacterBoundaryAndNeverSplitsAScalar() {
        XCTAssertEqual(AuthorityLabel.encode("iPhone").count, 16)
        XCTAssertEqual(AuthorityLabel.decode(AuthorityLabel.encode("iPhone")), "iPhone")

        // 16 bytes exactly, and the next character would not fit whole.
        let long = AuthorityLabel.encode("Sarah's iPhone 17 Pro Max")
        XCTAssertEqual(long.count, 16)
        XCTAssertNoThrow(try AuthorityLabel.validate(long))

        // An emoji is four bytes: the label stops before it rather than half way through it, which would
        // reach the server as a replacement character.
        let emoji = AuthorityLabel.encode("abcdefghijklmn🙂")
        XCTAssertEqual(AuthorityLabel.decode(emoji), "abcdefghijklmn")
        XCTAssertNoThrow(try AuthorityLabel.validate(emoji))
    }

    // MARK: - The preimage

    func testTheRecordPreimageIsTheMagicTheChallengeAndTheBytes() throws {
        let challenge = [UInt8](repeating: 0x07, count: 32)
        let bytes = try AuthorityRecord.adoptRoot(accountID: accountID,
                                                  deviceKey: deviceKey,
                                                  recoveryKey: recoveryKey,
                                                  label: "iPhone",
                                                  entropy: entropy)

        let preimage = try AuthorityProofs.recordPreimage(type: .adoptRoot, challenge: challenge, canonicalBytes: bytes)

        XCTAssertEqual(preimage.count, 4 + 32 + 177)
        XCTAssertEqual(Array(preimage[0..<4]), Array("GUAA".utf8))
        XCTAssertEqual(Array(preimage[4..<36]), challenge)
        XCTAssertEqual(Array(preimage[36...]), bytes)
    }

    func testTheSameBytesUnderAnotherMagicProduceAnotherPreimage() throws {
        // The magic is the signature domain, which is what stops a record being replayed as another type.
        let challenge = [UInt8](repeating: 0x07, count: 32)
        let grant = try AuthorityRecord.deviceGrant(accountID: accountID,
                                                    granteeKey: recoveryKey,
                                                    label: "iPad",
                                                    authorizingKey: deviceKey,
                                                    prevHash: AuthorityRecord.emptyPrevHash,
                                                    seq: 2)

        let asGrant = try AuthorityProofs.recordPreimage(type: .deviceGrant, challenge: challenge, canonicalBytes: grant)
        XCTAssertNotEqual(Array(asGrant[0..<4]), Array("GUAA".utf8))
        XCTAssertThrowsError(try AuthorityProofs.recordPreimage(type: .adoptRoot,
                                                                challenge: challenge,
                                                                canonicalBytes: grant),
                             "A 161-byte record is not an AdoptRoot, whatever magic is asked for.")
    }

    func testAPreimageRefusesAChallengeThatIsNotThirtyTwoBytes() throws {
        let bytes = try AuthorityRecord.adoptRoot(accountID: accountID,
                                                  deviceKey: deviceKey,
                                                  recoveryKey: recoveryKey,
                                                  label: "iPhone",
                                                  entropy: entropy)
        XCTAssertThrowsError(try AuthorityProofs.recordPreimage(type: .adoptRoot,
                                                                challenge: [UInt8](repeating: 0, count: 31),
                                                                canonicalBytes: bytes))
    }

    func testTheApprovalPreimageIsFixedLengthThroughout() throws {
        let approvalID = [UInt8](repeating: 0x01, count: 16)
        let actionDigest = [UInt8](repeating: 0x02, count: 32)
        let challenge = [UInt8](repeating: 0x03, count: 32)

        let preimage = try AuthorityProofs.approvalPreimage(accountID: accountID,
                                                            approvalID: approvalID,
                                                            actionDigest: actionDigest,
                                                            challenge: challenge)

        XCTAssertEqual(preimage.count, AuthorityProofs.approvalPreimageLength)
        XCTAssertEqual(preimage.count, 25 + 34 + 16 + 32 + 32)
        XCTAssertEqual(Array(preimage[0..<25]), Array("gua-authority-approval.v1".utf8))
        XCTAssertEqual(Array(preimage[25..<59]), accountID.rawBytes)
        XCTAssertEqual(Array(preimage[59..<75]), approvalID)
        XCTAssertEqual(Array(preimage[75..<107]), actionDigest)
        XCTAssertEqual(Array(preimage[107..<139]), challenge)
    }

    func testASignatureOverThePreimageVerifiesUnderTheDeviceKey() throws {
        // What the server does with the record it received, done here against the bytes this client
        // produced, which is the whole of what makes the two halves one protocol.
        let key = Curve25519.Signing.PrivateKey()
        let challenge = [UInt8](repeating: 0x09, count: 32)
        let bytes = try AuthorityRecord.adoptRoot(accountID: accountID,
                                                  deviceKey: [UInt8](key.publicKey.rawRepresentation),
                                                  recoveryKey: recoveryKey,
                                                  label: "iPhone",
                                                  entropy: entropy)
        let preimage = try AuthorityProofs.recordPreimage(type: .adoptRoot, challenge: challenge, canonicalBytes: bytes)
        let signature = try key.signature(for: Data(preimage))

        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: Data(preimage)))
        // The same signature against another challenge is not a signature at all: the challenge is inside
        // the signed bytes, not checked beside them.
        let otherPreimage = try AuthorityProofs.recordPreimage(type: .adoptRoot,
                                                               challenge: [UInt8](repeating: 0x0A, count: 32),
                                                               canonicalBytes: bytes)
        XCTAssertFalse(key.publicKey.isValidSignature(signature, for: Data(otherPreimage)))
    }

    // MARK: - Hashes

    func testARecordHashRoundTripsThroughItsHexForm() throws {
        let bytes = try AuthorityRecord.adoptRoot(accountID: accountID,
                                                  deviceKey: deviceKey,
                                                  recoveryKey: recoveryKey,
                                                  label: "iPhone",
                                                  entropy: entropy)
        let hex = AuthorityRecord.hash(bytes)

        XCTAssertEqual(hex.count, 64)
        XCTAssertEqual(AuthorityRecord.hashBytes(fromHex: hex), [UInt8](SHA256.hash(data: Data(bytes))))
        XCTAssertNil(AuthorityRecord.hashBytes(fromHex: "not a hash"))
        XCTAssertEqual(AuthorityRecord.hashBytes(fromHex: String(repeating: "0", count: 64)),
                       AuthorityRecord.emptyPrevHash,
                       "The 64 zeros an empty chain reports are the prevHash of its first record.")
    }

    // MARK: - The three types revision 4 and the lifecycle added

    func testARevocationCarriesItsReasonAndRefusesAnUnknownOne() throws {
        var bytes = try AuthorityRecord.deviceRevoke(accountID: accountID,
                                                     deviceKey: recoveryKey,
                                                     reason: AuthorityRecord.reasonLost,
                                                     authorizingKey: deviceKey,
                                                     prevHash: AuthorityRecord.emptyPrevHash,
                                                     seq: 3)
        XCTAssertEqual(bytes.count, 145)
        let decoded = try AuthorityRecord.decode(bytes)
        XCTAssertEqual(decoded.type, .deviceRevoke)
        // A revocation is signed by the key that authorizes it, never by the key it removes: the device
        // named in one may not veto its own removal, so it cannot be the signer either.
        XCTAssertEqual(decoded.verifyingKey, deviceKey)
        XCTAssertEqual(decoded.deviceKey, recoveryKey)

        bytes[112] = 0x05
        assertRefused(bytes, with: .unknownRevocationReason)
    }

    func testARecoveryEnforcesTheAuthorizationPairingInBothDirections() throws {
        let underTheRecoveryKey = try AuthorityRecord.authorityRecovery(accountID: accountID,
                                                                        deviceKey: deviceKey,
                                                                        recoveryKey: recoveryKey,
                                                                        label: "iPad",
                                                                        entropy: entropy,
                                                                        authorization: AuthorityRecord.authorizationRecoveryKey,
                                                                        authorizingKey: recoveryKey,
                                                                        prevHash: AuthorityRecord.emptyPrevHash,
                                                                        seq: 2)
        XCTAssertEqual(underTheRecoveryKey.count, 209)
        XCTAssertEqual(try AuthorityRecord.decode(underTheRecoveryKey).verifyingKey, recoveryKey)

        // Rank 0: the field is all zero by rule, and the signer is the device key being installed,
        // because the account has no other key left.
        let throughAccountRecovery = try AuthorityRecord.authorityRecovery(accountID: accountID,
                                                                           deviceKey: deviceKey,
                                                                           recoveryKey: recoveryKey,
                                                                           label: "iPad",
                                                                           entropy: entropy,
                                                                           authorization: AuthorityRecord.authorizationAccountRecovery,
                                                                           authorizingKey: recoveryKey,
                                                                           prevHash: AuthorityRecord.emptyPrevHash,
                                                                           seq: 2)
        XCTAssertEqual(Array(throughAccountRecovery[177..<209]), AuthorityRecord.zeroKey)
        XCTAssertEqual(try AuthorityRecord.decode(throughAccountRecovery).verifyingKey, deviceKey)

        var claimsTheKeyPathWithNoKey = underTheRecoveryKey
        claimsTheKeyPathWithNoKey.replaceSubrange(177..<209, with: AuthorityRecord.zeroKey)
        assertRefused(claimsTheKeyPathWithNoKey, with: .authorizingKeyRequired)

        var claimsRecoveryWithAKey = throughAccountRecovery
        claimsRecoveryWithAKey.replaceSubrange(177..<209, with: recoveryKey)
        assertRefused(claimsRecoveryWithAKey, with: .authorizingKeyNotPermitted)

        var unknownAuthorization = underTheRecoveryKey
        unknownAuthorization[176] = 0x03
        assertRefused(unknownAuthorization, with: .unknownAuthorization)

        XCTAssertThrowsError(try AuthorityRecord.authorityRecovery(accountID: accountID,
                                                                   deviceKey: deviceKey,
                                                                   recoveryKey: recoveryKey,
                                                                   label: "iPad",
                                                                   entropy: entropy,
                                                                   authorization: 0x03,
                                                                   authorizingKey: recoveryKey,
                                                                   prevHash: AuthorityRecord.emptyPrevHash,
                                                                   seq: 2)) { error in
            XCTAssertEqual(error as? AuthorityRecordError, .unknownAuthorization)
        }
    }

    func testAnOppositionNamesARecordAndRefusesNamingNone() throws {
        let opposed = [UInt8](repeating: 0x2B, count: 32)
        var bytes = try AuthorityRecord.oppose(accountID: accountID,
                                               opposedRecordHash: opposed,
                                               authorizingKey: deviceKey,
                                               prevHash: AuthorityRecord.emptyPrevHash,
                                               seq: 3)
        XCTAssertEqual(bytes.count, 144)
        let decoded = try AuthorityRecord.decode(bytes)
        XCTAssertEqual(decoded.type, .oppose)
        XCTAssertEqual(decoded.verifyingKey, deviceKey)
        // An Oppose names no device: it names a record.
        XCTAssertNil(decoded.deviceKey)

        bytes.replaceSubrange(80..<112, with: [UInt8](repeating: 0, count: 32))
        assertRefused(bytes, with: .zeroOpposedRecord)
    }

    // MARK: - The candidate fingerprint

    func testAFingerprintIsEightCharactersOfTheStatedAlphabet() throws {
        let fingerprint = try XCTUnwrap(AuthorityFingerprint.of(deviceKey))

        XCTAssertEqual(fingerprint.count, AuthorityFingerprint.length)
        XCTAssertTrue(fingerprint.allSatisfy { AuthorityFingerprint.alphabet.contains($0) })
        // The characters that look alike are what a fingerprint read aloud fails at. Asserted against the
        // alphabet identity-service publishes, character for character: I, O, 0, 1 and 5 are the ones it
        // actually leaves out, whatever its own comment claims, and a client that dropped one more would
        // compute a different fingerprint from the same key.
        XCTAssertEqual(String(AuthorityFingerprint.alphabet), "ABCDEFGHJKLMNPQRSTUVWXYZ2346789")
        XCTAssertFalse(AuthorityFingerprint.alphabet.contains { "IO015".contains($0) })
        XCTAssertEqual(AuthorityFingerprint.alphabet.count, 31)
        XCTAssertEqual(AuthorityFingerprint.grouped(fingerprint).count, AuthorityFingerprint.length + 1)
    }

    func testAFingerprintIsDerivedFromTheKeyAndNotFromItsBytes() {
        // Derived, never issued: both phones compute the same eight characters from the same 32 bytes,
        // which is what makes the human comparison mean the two are looking at one key.
        XCTAssertEqual(AuthorityFingerprint.of(deviceKey), AuthorityFingerprint.of(deviceKey))
        XCTAssertNotEqual(AuthorityFingerprint.of(deviceKey), AuthorityFingerprint.of(recoveryKey))
        // Taken from a digest rather than from the key's own leading bytes, so two keys that agree on
        // their first 31 bytes still read differently across a room.
        var sharesEveryByteButTheLast: [UInt8] = deviceKey
        sharesEveryByteButTheLast[31] ^= 0x01
        XCTAssertNotEqual(AuthorityFingerprint.of(deviceKey), AuthorityFingerprint.of(sharesEveryByteButTheLast))
        XCTAssertNotEqual(AuthorityFingerprint.of(deviceKey),
                          String(deviceKey.prefix(AuthorityFingerprint.length)
                              .map { AuthorityFingerprint.alphabet[Int($0) % AuthorityFingerprint.alphabet.count] }))
        XCTAssertNil(AuthorityFingerprint.of(Array(deviceKey.prefix(31))))
    }

    // MARK: - The notification binding

    func testTheNotificationPreimageIsTheDomainTheAccountTheInstallTheKeyAndTheChallenge() throws {
        let preimage = try AuthorityProofs.notificationPreimage(accountID: accountID,
                                                                installationID: "an-install",
                                                                deviceKey: deviceKey,
                                                                challenge: challenge)

        XCTAssertEqual(preimage.count, AuthorityProofs.notificationPreimageLength)
        XCTAssertEqual(Array(preimage.prefix(AuthorityProofs.notificationDomain.utf8.count)),
                       Array(AuthorityProofs.notificationDomain.utf8))
        // The installation id is hashed rather than carried, so every element is fixed length and no
        // field can be shifted into another.
        let domain = AuthorityProofs.notificationDomain.utf8.count
        let installOffset = domain + AccountID.rawLength
        XCTAssertEqual(Array(preimage[installOffset..<(installOffset + 32)]),
                       [UInt8](SHA256.hash(data: Data("an-install".utf8))))
        XCTAssertEqual(Array(preimage.suffix(32)), challenge)

        // A registration for another install is a different preimage, which is what stops one row's
        // signature being replayed onto another row.
        let other = try AuthorityProofs.notificationPreimage(accountID: accountID,
                                                             installationID: "another-install",
                                                             deviceKey: deviceKey,
                                                             challenge: challenge)
        XCTAssertNotEqual(preimage, other)
    }

    private func assertRefused(_ bytes: [UInt8],
                               with expected: AuthorityRecordError,
                               file: StaticString = #filePath,
                               line: UInt = #line) {
        XCTAssertThrowsError(try AuthorityRecord.validate(bytes), file: file, line: line) { error in
            XCTAssertEqual(error as? AuthorityRecordError, expected, file: file, line: line)
        }
    }
}
