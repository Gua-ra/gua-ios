//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import CryptoKit
@testable import ElementX
import XCTest

/// The codec against the golden vectors that ship with identity-service
/// (`docs/specs/genesis-vectors.v1.json`). That file is the contract, not the prose around it, so the
/// copy under `UnitTests/Resources` is byte-identical to the one in that repo and this suite walks
/// every entry in it, the rejections included.
///
/// One thing these tests deliberately do not assert: that a signature this client produces equals the
/// signature in the vectors. RFC 8032 signing is deterministic, but Apple's CryptoKit adds fresh
/// randomness to the nonce, so two signings of one message under one key differ. What is asserted
/// instead is the part the contract actually binds: the preimage bytes are reproduced exactly, the
/// published signatures verify under the published keys, and a signature this client makes verifies too.
final class AccountGenesisCodecTests: XCTestCase {
    private var vectors: GenesisVectors!

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "genesis-vectors.v1.json", withExtension: nil),
                                "The golden vectors are missing from the test bundle.")
        vectors = try JSONDecoder().decode(GenesisVectors.self, from: Data(contentsOf: url))
    }

    // MARK: - AccountGenesis

    func testAccountGenesisVectorsEncodeToTheCanonicalBytes() throws {
        for vector in vectors.accountGenesis {
            let encoded = try AccountGenesis.encode(authorityPublicKey: GenesisHex.bytes(vector.authorityPublicKeyHex),
                                                    recoveryFrameworkID: UInt8(vector.recoveryFrameworkId),
                                                    recoveryAuthorityPublicKey: GenesisHex.bytes(vector.recoveryAuthorityPublicKeyHex),
                                                    entropy: GenesisHex.bytes(vector.entropyHex))
            XCTAssertEqual(GenesisHex.string(encoded), vector.canonicalHex, vector.name)
            XCTAssertEqual(encoded.count, AccountGenesis.length, vector.name)
        }
    }

    func testAccountGenesisVectorsHashAndDeriveTheirAccountID() throws {
        for vector in vectors.accountGenesis {
            let canonical = GenesisHex.bytes(vector.canonicalHex)
            let digest = GenesisHex.string([UInt8](SHA256.hash(data: Data(canonical))))
            XCTAssertEqual(digest, vector.sha256Hex, vector.name)

            let genesis = try AccountGenesis.decode(canonical)
            XCTAssertEqual(try genesis.accountID().value, vector.accountId, vector.name)
            XCTAssertTrue(try genesis.accountID().isGenesisRooted, vector.name)
        }
    }

    func testAccountGenesisVectorsDecodeIntoTheirFields() throws {
        for vector in vectors.accountGenesis {
            let genesis = try AccountGenesis.decode(GenesisHex.bytes(vector.canonicalHex))
            XCTAssertEqual(genesis.genesisVersion, UInt8(vector.genesisVersion), vector.name)
            XCTAssertEqual(genesis.suite, UInt8(vector.suite), vector.name)
            XCTAssertEqual(genesis.recoveryFrameworkID, UInt8(vector.recoveryFrameworkId), vector.name)
            XCTAssertEqual(GenesisHex.string(genesis.authorityPublicKey), vector.authorityPublicKeyHex, vector.name)
            XCTAssertEqual(GenesisHex.string(genesis.recoveryAuthorityPublicKey), vector.recoveryAuthorityPublicKeyHex, vector.name)
            XCTAssertEqual(GenesisHex.string(genesis.entropy), vector.entropyHex, vector.name)
            // The bytes are kept as received, never re-encoded before hashing.
            XCTAssertEqual(GenesisHex.string(genesis.canonicalBytes), vector.canonicalHex, vector.name)
        }
    }

    func testPublishedRegistrationProofsVerify() throws {
        for vector in vectors.accountGenesis {
            let canonical = GenesisHex.bytes(vector.canonicalHex)
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: Data(GenesisHex.bytes(vector.authorityPublicKeyHex)))
            let signature = try XCTUnwrap(Data(base64Encoded: vector.genesisProofSignatureB64))
            let preimage = GenesisProofs.genesisProofPreimage(canonicalBytes: canonical)

            XCTAssertEqual(GenesisProofs.genesisProofDomain, vectors.genesisProofDomain)
            XCTAssertEqual(Array(preimage.prefix(vectors.genesisProofDomain.utf8.count)),
                           Array(vectors.genesisProofDomain.utf8), vector.name)
            XCTAssertTrue(publicKey.isValidSignature(signature, for: Data(preimage)), vector.name)
        }
    }

    func testAccountGenesisRejections() throws {
        for rejection in vectors.rejections.accountGenesis {
            let bytes = try GenesisHex.bytes(XCTUnwrap(rejection.hex))
            XCTAssertThrowsError(try AccountGenesis.decode(bytes), rejection.name) { error in
                XCTAssertEqual((error as? AccountGenesisError)?.reason, rejection.reason, rejection.name)
            }
        }
    }

    // MARK: - BootstrapGenesis

    func testBootstrapGenesisVectors() throws {
        for vector in vectors.bootstrapGenesis {
            let canonical = GenesisHex.bytes(vector.canonicalHex)
            XCTAssertEqual(GenesisHex.string([UInt8](SHA256.hash(data: Data(canonical)))), vector.sha256Hex, vector.name)

            let genesis = try BootstrapGenesis.decode(canonical)
            XCTAssertEqual(genesis.version, UInt8(vector.version), vector.name)
            XCTAssertEqual(genesis.suite, UInt8(vector.suite), vector.name)
            XCTAssertEqual(GenesisHex.string(genesis.entropy), vector.entropyHex, vector.name)
            XCTAssertEqual(try genesis.accountID().value, vector.accountId, vector.name)
            XCTAssertFalse(try genesis.accountID().isGenesisRooted, vector.name)
        }
    }

    func testBootstrapGenesisRejections() throws {
        for rejection in vectors.rejections.bootstrapGenesis {
            let bytes = try GenesisHex.bytes(XCTUnwrap(rejection.hex))
            XCTAssertThrowsError(try BootstrapGenesis.decode(bytes), rejection.name) { error in
                XCTAssertEqual((error as? AccountGenesisError)?.reason, rejection.reason, rejection.name)
            }
        }
    }

    // MARK: - accountId

    func testAccountIDSpellingRules() throws {
        XCTAssertEqual(AccountID.canonicalPattern, vectors.accountId.pattern)
        XCTAssertEqual(AccountID.prefix, vectors.accountId.prefix)
        XCTAssertEqual(Int(AccountID.formatVersion), vectors.accountId.formatVersion)
        XCTAssertEqual(Int(AccountID.classGenesis), vectors.accountId.rootClassGenesis)
        XCTAssertEqual(Int(AccountID.classBootstrap), vectors.accountId.rootClassBootstrap)
        XCTAssertEqual(AccountID.rawLength, vectors.accountId.rawLength)
        XCTAssertEqual(AccountID.encodedLength, vectors.accountId.encodedLength)
        XCTAssertEqual(AccountID.length, vectors.accountId.totalLength)

        // The last character holds three unused bits, so only these four can end a well-formed id.
        for vector in vectors.accountGenesis {
            let last = try XCTUnwrap(vector.accountId.last).description
            XCTAssertTrue(vectors.accountId.allowedFinalCharacters.contains(last), vector.name)
        }
    }

    func testAccountIDRoundTripsThroughParse() throws {
        for vector in vectors.accountGenesis {
            let parsed = try AccountID.parse(vector.accountId)
            XCTAssertEqual(parsed.value, vector.accountId, vector.name)
            XCTAssertEqual(parsed.rawBytes.count, AccountID.rawLength, vector.name)
            XCTAssertEqual(parsed.rootClass, AccountID.classGenesis, vector.name)
            // Deriving from the same bytes gives the same id, and the raw bytes agree.
            let derived = try AccountGenesis.decode(GenesisHex.bytes(vector.canonicalHex)).accountID()
            XCTAssertEqual(derived.rawBytes, parsed.rawBytes, vector.name)
        }
    }

    func testAccountIDRejections() throws {
        for rejection in vectors.rejections.accountId {
            let value = try XCTUnwrap(rejection.value)
            XCTAssertThrowsError(try AccountID.parse(value), rejection.name) { error in
                XCTAssertEqual((error as? AccountGenesisError)?.reason, rejection.reason, rejection.name)
            }
        }
    }

    // MARK: - Attach proof

    func testAttachProofPreimageMatchesTheVector() throws {
        let vector = vectors.attachProof
        XCTAssertEqual(GenesisProofs.attachProofDomain, vector.domain)
        XCTAssertEqual(GenesisProofs.attachProofDomain.utf8.count, vector.domainLength)
        XCTAssertEqual(GenesisProofs.attachPreimageLength, vector.preimageLength)

        let accountID = try AccountID.parse(vector.accountId)
        XCTAssertEqual(GenesisHex.string(accountID.rawBytes), vector.accountIdRawHex)

        let preimage = try GenesisProofs.attachProofPreimage(challenge: GenesisHex.bytes(vector.challengeHex),
                                                             accountID: accountID)
        XCTAssertEqual(GenesisHex.string(preimage), vector.preimageHex)
        XCTAssertEqual(preimage.count, vector.preimageLength)
    }

    func testPublishedAttachProofVerifies() throws {
        let vector = vectors.attachProof
        let authority = try XCTUnwrap(vectors.accountGenesis.first)
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: Data(GenesisHex.bytes(authority.authorityPublicKeyHex)))
        let preimage = try GenesisProofs.attachProofPreimage(challenge: GenesisHex.bytes(vector.challengeHex),
                                                             accountID: AccountID.parse(vector.accountId))
        let signature = try XCTUnwrap(Data(base64Encoded: vector.signatureB64))
        XCTAssertTrue(publicKey.isValidSignature(signature, for: Data(preimage)))
    }

    func testAttachProofRejectsAWrongLengthChallenge() throws {
        let accountID = try AccountID.parse(vectors.attachProof.accountId)
        XCTAssertThrowsError(try GenesisProofs.attachProofPreimage(challenge: [UInt8](repeating: 0, count: 31),
                                                                   accountID: accountID)) { error in
            XCTAssertEqual((error as? AccountGenesisError)?.reason, AccountGenesisError.wrongLength.reason)
        }
    }

    // MARK: - Keys this device generates

    func testAGenesisBuiltFromFreshKeysRoundTrips() throws {
        let authority = Curve25519.Signing.PrivateKey()
        let recovery = Curve25519.Signing.PrivateKey()
        var entropy = [UInt8](repeating: 0, count: AccountGenesis.entropyLength)
        XCTAssertEqual(SecRandomCopyBytes(kSecRandomDefault, entropy.count, &entropy), errSecSuccess)

        let canonical = try AccountGenesis.encode(authorityPublicKey: [UInt8](authority.publicKey.rawRepresentation),
                                                  recoveryAuthorityPublicKey: [UInt8](recovery.publicKey.rawRepresentation),
                                                  entropy: entropy)
        let genesis = try AccountGenesis.decode(canonical)
        let accountID = try genesis.accountID()

        XCTAssertEqual(accountID.value.count, AccountID.length)
        XCTAssertNotNil(accountID.value.range(of: AccountID.canonicalPattern, options: .regularExpression))
        XCTAssertEqual(try AccountID.parse(accountID.value), accountID)

        // A proof this client makes verifies under the key the genesis commits, which is what
        // identity-service checks on registration.
        let signature = try authority.signature(for: Data(GenesisProofs.genesisProofPreimage(canonicalBytes: canonical)))
        XCTAssertTrue(authority.publicKey.isValidSignature(signature,
                                                           for: Data(GenesisProofs.genesisProofPreimage(canonicalBytes: canonical))))
    }

    func testBase32RejectsNonCanonicalSpellings() {
        // Uppercase, padding and a character outside the alphabet are all refused, because each would
        // give one byte string a second spelling.
        XCTAssertThrowsError(try GuaBase32.decode("AAAA"))
        XCTAssertThrowsError(try GuaBase32.decode("aaaa===="))
        XCTAssertThrowsError(try GuaBase32.decode("aaa1"))
        // 1, 3 and 6 left-over characters cannot come out of any byte string.
        XCTAssertThrowsError(try GuaBase32.decode("a"))
        XCTAssertThrowsError(try GuaBase32.decode("aaa"))
        XCTAssertThrowsError(try GuaBase32.decode("aaaaaa"))
        // Non-zero trailing bits.
        XCTAssertThrowsError(try GuaBase32.decode("ab"))
        XCTAssertEqual(try GuaBase32.decode("aa"), [0])
    }
}

// MARK: - Vectors

private enum GenesisHex {
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

private struct GenesisVectors: Decodable {
    struct GenesisVector: Decodable {
        let name: String
        let genesisVersion: Int
        let suite: Int
        let recoveryFrameworkId: Int
        let authorityPublicKeyHex: String
        let recoveryAuthorityPublicKeyHex: String
        let entropyHex: String
        let canonicalHex: String
        let sha256Hex: String
        let accountId: String
        let genesisProofSignatureB64: String
    }

    struct BootstrapVector: Decodable {
        let name: String
        let version: Int
        let suite: Int
        let entropyHex: String
        let canonicalHex: String
        let sha256Hex: String
        let accountId: String
    }

    struct AttachProofVector: Decodable {
        let domain: String
        let domainLength: Int
        let preimageLength: Int
        let accountId: String
        let accountIdRawHex: String
        let challengeHex: String
        let preimageHex: String
        let signatureB64: String
    }

    struct AccountIDSpec: Decodable {
        let pattern: String
        let allowedFinalCharacters: [String]
        let prefix: String
        let formatVersion: Int
        let rootClassGenesis: Int
        let rootClassBootstrap: Int
        let rawLength: Int
        let encodedLength: Int
        let totalLength: Int
    }

    struct Rejection: Decodable {
        let name: String
        let hex: String?
        let value: String?
        let reason: String
    }

    struct Rejections: Decodable {
        let accountGenesis: [Rejection]
        let bootstrapGenesis: [Rejection]
        let accountId: [Rejection]
    }

    let accountGenesis: [GenesisVector]
    let genesisProofDomain: String
    let bootstrapGenesis: [BootstrapVector]
    let attachProof: AttachProofVector
    let accountId: AccountIDSpec
    let rejections: Rejections
}
