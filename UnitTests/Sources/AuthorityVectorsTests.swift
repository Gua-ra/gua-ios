//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import CryptoKit
@testable import ElementX
import XCTest

/// The authority chain against the golden vectors that ship with identity-service
/// (`docs/specs/authority-vectors.v1.json`). That file is the contract, not the prose around it, so the
/// copy under `UnitTests/Resources` is byte-identical to the one in that repo and this suite walks every
/// entry in it, the sixteen rejections included.
///
/// Three implementations have to agree on 177, 161, 145, 209 and 144 bytes, on which field sits at which
/// offset, and on what a decoder refuses. A cross-platform byte format that only one implementation has
/// ever produced is a format with one implementation, which is why the agreement is tested here rather
/// than asserted in a comment.
///
/// One thing these tests deliberately do not assert, exactly as ``AccountGenesisCodecTests`` does not:
/// that a signature this client produces equals the signature in the vectors. RFC 8032 signing is
/// deterministic and the server reproduces every `signatureB64` from its key and its preimage, but
/// CryptoKit adds fresh randomness to the nonce, so two signings of one message under one key differ.
/// What is asserted instead is the part the contract binds: the canonical bytes, the hashes, the preimage
/// of the one rule every type obeys, and that the published signatures verify under the published keys
/// and under nothing else.
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
            // A type with no vector is a type each port implements from the prose and nobody compares.
            XCTAssertTrue(magics.contains(type.rawValue), "a vector for \(type.rawValue)")
        }
    }

    func testTheAccountReferenceIsTheOneItsAccountIDDerivesTo() throws {
        let accountID = try AccountID.parse(vectors.account.accountId)

        // The 34 bytes at offset 6 of every envelope are exactly what AccountID.rawBytes holds, so a
        // client that builds them some other way builds records this server refuses.
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
            // The bytes are kept as received. The record hash is what the next record's prevHash must
            // equal, so a decoder that re-encoded would be hashing something else.
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

            // The one preimage rule, checked as bytes rather than as prose: magic, then the challenge,
            // then the canonical bytes, in that order and nothing between them.
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

            // This is the whole freshness property: a record signed for one transition is not
            // resubmittable after it was opposed, and is not precomputable on other hardware.
            XCTAssertFalse(key.isValidSignature(signature, for: Data(preimage)), vector.name)
        }
    }

    func testASignatureDoesNotVerifyAsAnotherRecordType() throws {
        for vector in vectors.records {
            let canonical = AuthorityHex.bytes(vector.canonicalHex)
            let decoded = try AuthorityRecord.decode(canonical)
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(decoded.verifyingKey))
            let signature = try XCTUnwrap(Data(base64Encoded: vector.signatureB64), vector.name)

            // The magic is the signature domain, so swapping it changes the preimage. A verifier for one
            // type never reaches the preimage of another.
            for other in AuthorityRecordType.allCases where other != decoded.type {
                let preimage = other.magic + challenge + canonical
                XCTAssertFalse(key.isValidSignature(signature, for: Data(preimage)),
                               "\(vector.name) as \(other.rawValue)")
            }
        }
    }

    // MARK: - This client builds the same bytes

    /// The builders, against the two records this device signs on the adoption and grant paths.
    ///
    /// The inputs are the vectors' own published constants, so this is the real cross-platform check:
    /// given those bytes, `AuthorityRecord` has to produce that hex and no other.
    func testTheBuildersProduceTheVectorsByteForByte() throws {
        let accountID = try AccountID.parse(vectors.account.accountId)
        let test1 = try AuthorityHex.bytes(XCTUnwrap(vectors.keys["rfc8032-test1"]?.publicKeyHex))
        let test2 = try AuthorityHex.bytes(XCTUnwrap(vectors.keys["rfc8032-test2"]?.publicKeyHex))
        let test3 = try AuthorityHex.bytes(XCTUnwrap(vectors.keys["rfc8032-test3"]?.publicKeyHex))
        // The label and the entropy the records carry, read off the vectors rather than invented: the
        // adoption is labelled "iPhone" and every other record "iPad".
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

        // Under the account-recovery path the authorizing key is 32 zero bytes by rule, whatever the
        // caller passes, which is why the builder writes them rather than trusting the argument.
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

        // The Oppose carries the seq and prevHash of the record it cancels, because it takes no slot and
        // is never appended to the chain.
        let revocationHash = try XCTUnwrap(AuthorityRecord.hashBytes(fromHex: AuthorityRecord.hash(revocation)))
        let opposition = try AuthorityRecord.oppose(accountID: accountID,
                                                    opposedRecordHash: revocationHash,
                                                    authorizingKey: test1,
                                                    prevHash: grantHash,
                                                    seq: 3)
        XCTAssertEqual(AuthorityHex.string(opposition), try vector(named: "GUAO").canonicalHex)
    }

    // MARK: - The recovery artifact

    /// The one thing in this contract the server never sees, which is why it is pinned here.
    ///
    /// What crosses the wire for a recovery is a signature by the key the artifact carries, so nothing on
    /// the wire can catch two clients rendering two spellings of it. The bill for that arrives in the one
    /// case `AuthorityRecovery` exists for: a person who took the artifact on one phone and is typing it
    /// into the replacement. This vector is the agreement, and this is the suite that holds this port to it.
    func testTheArtifactIsTheOneSpellingEveryPortRendersAndReadsBack() throws {
        let artifacts = vectors.recoveryArtifact
        XCTAssertEqual(AuthorityRecoveryArtifact.prefix, artifacts.prefix)
        XCTAssertEqual(AuthorityRecoveryArtifact.encodedLength, artifacts.encodedLength)
        XCTAssertFalse(artifacts.vectors.isEmpty)

        for vector in artifacts.vectors {
            let seed = try AuthorityHex.bytes(publicKeySeed(named: vector.key))
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(seed))
            XCTAssertEqual(AuthorityRecoveryArtifact.render(key), vector.artifact, vector.key)

            // Every spelling of the same artifact a person could plausibly type back. The spacing is
            // free-form on the way in, because nobody reproduces the printed groups exactly.
            let rewrapped = vector.artifact.replacingOccurrences(of: " ", with: "  ")
            let body = vector.artifact.dropFirst(artifacts.prefix.count).filter { !$0.isWhitespace }
            for typed in [vector.artifact, "  \(rewrapped)\n", "\(artifacts.prefix) \(body)"] {
                XCTAssertEqual(try AuthorityRecoveryArtifact.parse(typed).rawRepresentation, Data(seed), typed)
                XCTAssertTrue(AuthorityRecoveryArtifact.looksComplete(typed), typed)
            }
        }

        for rejection in artifacts.rejections {
            // This port answers one refusal for all of them. The reason in the file names what each entry
            // is wrong about, and refusing every one of them is what conformance is.
            XCTAssertThrowsError(try AuthorityRecoveryArtifact.parse(rejection.artifact), rejection.name) { error in
                XCTAssertEqual(error as? AccountAuthorityServiceError, .artifactMalformed, rejection.name)
            }
            XCTAssertFalse(AuthorityRecoveryArtifact.looksComplete(rejection.artifact), rejection.name)
        }
    }

    /// The case an artifact comes back in, which is the divergence these entries were added to close.
    ///
    /// It is written on paper in capitals and typed back through a keyboard that capitalises, and the two
    /// ports read it. Until these entries existed both suites passed with one port case-sensitive and the
    /// other not, which is the interop failure the artifact exists to avoid, reached by the narrowest route
    /// there is: the owner types their own key and one of their two phones says no.
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
                // The fold is ASCII and stops there. A scalar some Unicode mapping would turn into an
                // alphabet letter is not the case of anything that was printed.
                XCTAssertThrowsError(try AuthorityRecoveryArtifact.parse(spelling.artifact), spelling.name) { error in
                    XCTAssertEqual(error as? AccountAuthorityServiceError, .artifactMalformed, spelling.name)
                }
            }
        }

        // And what is handed out is still lowercase. Only the reader forgives.
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
                // The reason, not just the refusal: a client that refused everything with one token could
                // not tell a client bug from a wire change.
                XCTAssertEqual((error as? AuthorityRecordError)?.reason, rejection.reason, rejection.name)
            }
        }
    }

    private func vector(named magic: String) throws -> AuthorityVectors.Record {
        try XCTUnwrap(vectors.records.first { $0.magic == magic }, magic)
    }

    /// The one `GUAR` vector whose signer is `key`. There are two, and the pair is the point: the
    /// authorization byte decides which key signs, so a test that took the first one would pass either way.
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

    /// The artifact of ADM-009 decision 7, as a person copies it. The server holds no part of this one.
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

        /// A spelling of one of the artifacts above that a person plausibly types back and no renderer
        /// produces. It names a key when it must read back to that key, and a reason when it must be refused.
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
