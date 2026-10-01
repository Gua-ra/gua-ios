//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import CryptoKit
@testable import ElementX
import XCTest

/// `authority-vectors.v1.json` is byte-identical to the copy in identity-service.
/// Published signatures are verified, never compared with fresh ones: CryptoKit's Ed25519 signing is randomized.
final class AuthorityVectorsTests: XCTestCase {
    private var vectors: AuthorityVectors!
    private var challenge: [UInt8]!

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "authority-vectors.v1.json", withExtension: nil),
                                "The golden vectors are missing from the test bundle.")
        vectors = try JSONDecoder().decode(AuthorityVectors.self, from: Data(contentsOf: url))
        challenge = AuthorityHex.bytes(vectors.challengeHex)
    }

    // MARK: - The file covers what the chain has

    func testTheVectorsCoverEveryRecordTypeTheChainHas() {
        let magics = Set(vectors.records.map(\.magic))
        for type in AuthorityRecordType.allCases {
            XCTAssertTrue(magics.contains(type.rawValue), "a vector for \(type.rawValue)")
        }
    }

    func testTheAccountReferenceIsTheOneItsAccountIDDerivesTo() throws {
        let accountID = try AccountID.parse(vectors.account.accountId)

        XCTAssertEqual(AuthorityHex.string(accountID.rawBytes), vectors.account.rawBytesHex)
        XCTAssertEqual(accountID.rootClass, UInt8(vectors.account.rootClass))
        XCTAssertFalse(accountID.isGenesisRooted)
    }

    // MARK: - Every record

    func testEveryRecordDecodesToWhatItSaysItIs() throws {
        let accountReference = AuthorityHex.bytes(vectors.account.rawBytesHex)

        for vector in vectors.records {
            let canonical = AuthorityHex.bytes(vector.canonicalHex)
            XCTAssertEqual(canonical.count, vector.length, vector.name)

            let decoded = try AuthorityRecord.decode(canonical)
            XCTAssertEqual(decoded.type.rawValue, vector.magic, vector.name)
            XCTAssertEqual(decoded.seq, UInt64(vector.seq), vector.name)
            XCTAssertEqual(AuthorityRecord.hash(canonical), vector.sha256Hex, vector.name)
            XCTAssertEqual(AuthorityHex.string(decoded.verifyingKey), vector.verifyingKeyHex, vector.name)
            XCTAssertEqual(decoded.accountReference, accountReference, vector.name)
            XCTAssertEqual(decoded.canonicalBytes, canonical, vector.name)
        }
    }

    func testEveryPublishedSignatureVerifiesAgainstItsPreimage() throws {
        for vector in vectors.records {
            let canonical = AuthorityHex.bytes(vector.canonicalHex)
            let decoded = try AuthorityRecord.decode(canonical)
            let preimage = try AuthorityProofs.recordPreimage(type: decoded.type,
                                                              challenge: challenge,
                                                              canonicalBytes: canonical)

            XCTAssertEqual(AuthorityHex.string([UInt8](SHA256.hash(data: Data(preimage)))),
                           vector.preimageSha256Hex, vector.name)
            XCTAssertEqual(Array(preimage.prefix(AuthorityRecord.magicLength)), decoded.type.magic, vector.name)

            let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(decoded.verifyingKey))
            let signature = try XCTUnwrap(Data(base64Encoded: vector.signatureB64), vector.name)
            XCTAssertTrue(key.isValidSignature(signature, for: Data(preimage)), vector.name)
        }
    }

    func testASignatureDoesNotVerifyAgainstAnotherChallenge() throws {
        let other = [UInt8](SHA256.hash(data: Data("not the challenge these were signed against".utf8)))

        for vector in vectors.records {
            let canonical = AuthorityHex.bytes(vector.canonicalHex)
            let decoded = try AuthorityRecord.decode(canonical)
            let preimage = try AuthorityProofs.recordPreimage(type: decoded.type,
                                                              challenge: other,
                                                              canonicalBytes: canonical)
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(decoded.verifyingKey))
            let signature = try XCTUnwrap(Data(base64Encoded: vector.signatureB64), vector.name)

            XCTAssertFalse(key.isValidSignature(signature, for: Data(preimage)), vector.name)
        }
    }

    func testASignatureDoesNotVerifyAsAnotherRecordType() throws {
        for vector in vectors.records {
            let canonical = AuthorityHex.bytes(vector.canonicalHex)
            let decoded = try AuthorityRecord.decode(canonical)
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(decoded.verifyingKey))
            let signature = try XCTUnwrap(Data(base64Encoded: vector.signatureB64), vector.name)

            for other in AuthorityRecordType.allCases where other != decoded.type {
                let preimage = other.magic + challenge + canonical
                XCTAssertFalse(key.isValidSignature(signature, for: Data(preimage)),
                               "\(vector.name) as \(other.rawValue)")
            }
        }
    }

    // MARK: - This client builds the same bytes

    func testTheBuildersProduceTheVectorsByteForByte() throws {
        let accountID = try AccountID.parse(vectors.account.accountId)
        let test1 = try AuthorityHex.bytes(XCTUnwrap(vectors.keys["rfc8032-test1"]?.publicKeyHex))
        let test2 = try AuthorityHex.bytes(XCTUnwrap(vectors.keys["rfc8032-test2"]?.publicKeyHex))
        let test3 = try AuthorityHex.bytes(XCTUnwrap(vectors.keys["rfc8032-test3"]?.publicKeyHex))
        let entropy = AuthorityHex.bytes("f0e1d2c3b4a5968778695a4b3c2d1e0f")

        let adoption = try AuthorityRecord.adoptRoot(accountID: accountID,
                                                     deviceKey: test1,
                                                     recoveryKey: test2,
                                                     label: "iPhone",
                                                     entropy: entropy)
        XCTAssertEqual(AuthorityHex.string(adoption), try vector(named: "GUAA").canonicalHex)

        let adoptionHash = try XCTUnwrap(AuthorityRecord.hashBytes(fromHex: AuthorityRecord.hash(adoption)))
        let grant = try AuthorityRecord.deviceGrant(accountID: accountID,
                                                    granteeKey: test3,
                                                    label: "iPad",
                                                    authorizingKey: test1,
                                                    prevHash: adoptionHash,
                                                    seq: 2)
        XCTAssertEqual(AuthorityHex.string(grant), try vector(named: "GUAD").canonicalHex)

        let grantHash = try XCTUnwrap(AuthorityRecord.hashBytes(fromHex: AuthorityRecord.hash(grant)))
        let revocation = try AuthorityRecord.deviceRevoke(accountID: accountID,
                                                          deviceKey: test3,
                                                          reason: AuthorityRecord.reasonCompromised,
                                                          authorizingKey: test1,
                                                          prevHash: grantHash,
                                                          seq: 3)
        XCTAssertEqual(AuthorityHex.string(revocation), try vector(named: "GUAX").canonicalHex)

        let recovery = try AuthorityRecord.authorityRecovery(accountID: accountID,
                                                             deviceKey: test3,
                                                             recoveryKey: test1,
                                                             label: "iPad",
                                                             entropy: entropy,
                                                             authorization: AuthorityRecord.authorizationRecoveryKey,
                                                             authorizingKey: test2,
                                                             prevHash: adoptionHash,
                                                             seq: 2)
        XCTAssertEqual(AuthorityHex.string(recovery), try recoveryVector(signedBy: "rfc8032-test2").canonicalHex)

        let throughRecovery = try AuthorityRecord.authorityRecovery(accountID: accountID,
                                                                    deviceKey: test3,
                                                                    recoveryKey: test1,
                                                                    label: "iPad",
                                                                    entropy: entropy,
                                                                    authorization: AuthorityRecord.authorizationAccountRecovery,
                                                                    authorizingKey: test2,
                                                                    prevHash: adoptionHash,
                                                                    seq: 2)
        XCTAssertEqual(AuthorityHex.string(throughRecovery),
                       try recoveryVector(signedBy: "rfc8032-test3").canonicalHex)

        let revocationHash = try XCTUnwrap(AuthorityRecord.hashBytes(fromHex: AuthorityRecord.hash(revocation)))
        let opposition = try AuthorityRecord.oppose(accountID: accountID,
                                                    opposedRecordHash: revocationHash,
                                                    authorizingKey: test1,
                                                    prevHash: grantHash,
                                                    seq: 3)
        XCTAssertEqual(AuthorityHex.string(opposition), try vector(named: "GUAO").canonicalHex)
    }

    // MARK: - The recovery artifact

    func testTheArtifactIsTheOneSpellingEveryPortRendersAndReadsBack() throws {
        let artifacts = vectors.recoveryArtifact
        XCTAssertEqual(AuthorityRecoveryArtifact.prefix, artifacts.prefix)
        XCTAssertEqual(AuthorityRecoveryArtifact.encodedLength, artifacts.encodedLength)
        XCTAssertFalse(artifacts.vectors.isEmpty)

        for vector in artifacts.vectors {
            let seed = try AuthorityHex.bytes(publicKeySeed(named: vector.key))
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(seed))
            XCTAssertEqual(AuthorityRecoveryArtifact.render(key), vector.artifact, vector.key)

            let rewrapped = vector.artifact.replacingOccurrences(of: " ", with: "  ")
            let body = vector.artifact.dropFirst(artifacts.prefix.count).filter { !$0.isWhitespace }
            for typed in [vector.artifact, "  \(rewrapped)\n", "\(artifacts.prefix) \(body)"] {
                XCTAssertEqual(try AuthorityRecoveryArtifact.parse(typed).rawRepresentation, Data(seed), typed)
                XCTAssertTrue(AuthorityRecoveryArtifact.looksComplete(typed), typed)
            }
        }

        for rejection in artifacts.rejections {
            XCTAssertThrowsError(try AuthorityRecoveryArtifact.parse(rejection.artifact), rejection.name) { error in
                XCTAssertEqual(error as? AccountAuthorityServiceError, .artifactMalformed, rejection.name)
            }
            XCTAssertFalse(AuthorityRecoveryArtifact.looksComplete(rejection.artifact), rejection.name)
        }
    }

    func testTheArtifactReadsBackInWhateverCaseItWasTypedIn() throws {
        let artifacts = vectors.recoveryArtifact
        XCTAssertFalse(artifacts.spellings.isEmpty)
        XCTAssertTrue(artifacts.spellings.contains { $0.key != nil }, "an accepted spelling")
        XCTAssertTrue(artifacts.spellings.contains { $0.reason != nil }, "a refused spelling")

        for spelling in artifacts.spellings {
            if let key = spelling.key {
                let seed = try AuthorityHex.bytes(publicKeySeed(named: key))
                XCTAssertEqual(try AuthorityRecoveryArtifact.parse(spelling.artifact).rawRepresentation,
                               Data(seed),
                               spelling.name)
                XCTAssertTrue(AuthorityRecoveryArtifact.looksComplete(spelling.artifact), spelling.name)
            } else {
                XCTAssertThrowsError(try AuthorityRecoveryArtifact.parse(spelling.artifact), spelling.name) { error in
                    XCTAssertEqual(error as? AccountAuthorityServiceError, .artifactMalformed, spelling.name)
                }
            }
        }

        for vector in artifacts.vectors {
            XCTAssertEqual(vector.artifact, vector.artifact.lowercased(), vector.key)
        }
    }

    // MARK: - Every rejection

    func testEveryRejectionIsRefusedByTheRuleThatNamesIt() throws {
        XCTAssertEqual(vectors.rejections.count, 16, "the published rejection count")

        for rejection in vectors.rejections {
            let bytes = AuthorityHex.bytes(rejection.hex)
            XCTAssertThrowsError(try AuthorityRecord.decode(bytes), rejection.name) { error in
                XCTAssertEqual((error as? AuthorityRecordError)?.reason, rejection.reason, rejection.name)
            }
        }
    }

    private func vector(named magic: String) throws -> AuthorityVectors.Record {
        try XCTUnwrap(vectors.records.first { $0.magic == magic }, magic)
    }

    private func recoveryVector(signedBy key: String) throws -> AuthorityVectors.Record {
        let publicKeyHex = try publicKey(named: key)
        return try XCTUnwrap(vectors.records.first { $0.magic == "GUAR" && $0.verifyingKeyHex == publicKeyHex }, key)
    }

    private func publicKey(named key: String) throws -> String {
        try XCTUnwrap(vectors.keys[key], key).publicKeyHex
    }

    private func publicKeySeed(named key: String) throws -> String {
        try XCTUnwrap(vectors.keys[key], key).seedHex
    }
}

// MARK: - The file

private struct AuthorityVectors: Decodable {
    struct Key: Decodable {
        let seedHex: String
        let publicKeyHex: String
    }

    struct Account: Decodable {
        let accountId: String
        let rootClass: Int
        let entropyHex: String
        let rawBytesHex: String
    }

    struct Record: Decodable {
        let name: String
        let magic: String
        let seq: Int
        let length: Int
        let canonicalHex: String
        let sha256Hex: String
        let preimageSha256Hex: String
        let verifyingKeyHex: String
        let signatureB64: String
    }

    struct Rejection: Decodable {
        let name: String
        let hex: String
        let reason: String
    }

    struct RecoveryArtifact: Decodable {
        struct Vector: Decodable {
            let key: String
            let artifact: String
        }

        struct Rejection: Decodable {
            let name: String
            let artifact: String
            let reason: String
        }

        struct Spelling: Decodable {
            let name: String
            let artifact: String
            let key: String?
            let reason: String?
        }

        let prefix: String
        let groupSize: Int
        let encodedLength: Int
        let vectors: [Vector]
        let spellings: [Spelling]
        let rejections: [Rejection]
    }

    let keys: [String: Key]
    let account: Account
    let recoveryArtifact: RecoveryArtifact
    let challengeHex: String
    let records: [Record]
    let rejections: [Rejection]
}

private enum AuthorityHex {
    static func bytes(_ hex: String) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            if let value = UInt8(hex[index..<next], radix: 16) { out.append(value) }
            index = next
        }
        return out
    }

    static func string(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
