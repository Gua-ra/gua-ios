//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import CryptoKit
@testable import ElementX
import Foundation
import Testing

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
final class AccountGenesisCodecTests {
    private var vectors: GenesisVectors!
    
    init() throws {
        let url = try #require(Bundle(for: Self.self).url(forResource: "genesis-vectors.v1.json", withExtension: nil), "The golden vectors are missing from the test bundle.")
        vectors = try JSONDecoder().decode(GenesisVectors.self, from: Data(contentsOf: url))
    }
    
    // MARK: - AccountGenesis
    
    @Test
    func accountGenesisVectorsEncodeToTheCanonicalBytes() throws {
        for vector in vectors.accountGenesis {
            let encoded = try AccountGenesis.encode(authorityPublicKey: GenesisHex.bytes(vector.authorityPublicKeyHex),
                                                    recoveryFrameworkID: UInt8(vector.recoveryFrameworkId),
                                                    recoveryAuthorityPublicKey: GenesisHex.bytes(vector.recoveryAuthorityPublicKeyHex),
                                                    entropy: GenesisHex.bytes(vector.entropyHex))
            #expect(GenesisHex.string(encoded) == vector.canonicalHex, Comment(rawValue: vector.name))
            #expect(encoded.count == AccountGenesis.length, Comment(rawValue: vector.name))
        }
    }
    
    @Test
    func accountGenesisVectorsHashAndDeriveTheirAccountID() throws {
        for vector in vectors.accountGenesis {
            let canonical = GenesisHex.bytes(vector.canonicalHex)
            let digest = GenesisHex.string([UInt8](SHA256.hash(data: Data(canonical))))
            #expect(digest == vector.sha256Hex, Comment(rawValue: vector.name))
            
            let genesis = try AccountGenesis.decode(canonical)
            #expect(try genesis.accountID().value == vector.accountId, Comment(rawValue: vector.name))
            #expect(try genesis.accountID().isGenesisRooted, Comment(rawValue: vector.name))
        }
    }
    
    @Test
    func accountGenesisVectorsDecodeIntoTheirFields() throws {
        for vector in vectors.accountGenesis {
            let genesis = try AccountGenesis.decode(GenesisHex.bytes(vector.canonicalHex))
            #expect(genesis.genesisVersion == UInt8(vector.genesisVersion), Comment(rawValue: vector.name))
            #expect(genesis.suite == UInt8(vector.suite), Comment(rawValue: vector.name))
            #expect(genesis.recoveryFrameworkID == UInt8(vector.recoveryFrameworkId), Comment(rawValue: vector.name))
            #expect(GenesisHex.string(genesis.authorityPublicKey) == vector.authorityPublicKeyHex, Comment(rawValue: vector.name))
            #expect(GenesisHex.string(genesis.recoveryAuthorityPublicKey) == vector.recoveryAuthorityPublicKeyHex, Comment(rawValue: vector.name))
            #expect(GenesisHex.string(genesis.entropy) == vector.entropyHex, Comment(rawValue: vector.name))
            // The bytes are kept as received, never re-encoded before hashing.
            #expect(GenesisHex.string(genesis.canonicalBytes) == vector.canonicalHex, Comment(rawValue: vector.name))
        }
    }
    
    @Test
    func publishedRegistrationProofsVerify() throws {
        for vector in vectors.accountGenesis {
            let canonical = GenesisHex.bytes(vector.canonicalHex)
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: Data(GenesisHex.bytes(vector.authorityPublicKeyHex)))
            let signature = try #require(Data(base64Encoded: vector.genesisProofSignatureB64))
            let preimage = GenesisProofs.genesisProofPreimage(canonicalBytes: canonical)
            
            #expect(GenesisProofs.genesisProofDomain == vectors.genesisProofDomain)
            #expect(Array(preimage.prefix(vectors.genesisProofDomain.utf8.count)) == Array(vectors.genesisProofDomain.utf8), Comment(rawValue: vector.name))
            #expect(publicKey.isValidSignature(signature, for: Data(preimage)), Comment(rawValue: vector.name))
        }
    }
    
    @Test
    func accountGenesisRejections() throws {
        for rejection in vectors.rejections.accountGenesis {
            let bytes = try GenesisHex.bytes(#require(rejection.hex))
            let error = try #require(throws: (any Error).self, Comment(rawValue: rejection.name)) {
                try AccountGenesis.decode(bytes)
            }
            #expect((error as? AccountGenesisError)?.reason == rejection.reason, Comment(rawValue: rejection.name))
        }
    }
    
    // MARK: - BootstrapGenesis
    
    @Test
    func bootstrapGenesisVectors() throws {
        for vector in vectors.bootstrapGenesis {
            let canonical = GenesisHex.bytes(vector.canonicalHex)
            #expect(GenesisHex.string([UInt8](SHA256.hash(data: Data(canonical)))) == vector.sha256Hex, Comment(rawValue: vector.name))
            
            let genesis = try BootstrapGenesis.decode(canonical)
            #expect(genesis.version == UInt8(vector.version), Comment(rawValue: vector.name))
            #expect(genesis.suite == UInt8(vector.suite), Comment(rawValue: vector.name))
            #expect(GenesisHex.string(genesis.entropy) == vector.entropyHex, Comment(rawValue: vector.name))
            #expect(try genesis.accountID().value == vector.accountId, Comment(rawValue: vector.name))
            #expect(try !genesis.accountID().isGenesisRooted, Comment(rawValue: vector.name))
        }
    }
    
    @Test
    func bootstrapGenesisRejections() throws {
        for rejection in vectors.rejections.bootstrapGenesis {
            let bytes = try GenesisHex.bytes(#require(rejection.hex))
            let error = try #require(throws: (any Error).self, Comment(rawValue: rejection.name)) {
                try BootstrapGenesis.decode(bytes)
            }
            #expect((error as? AccountGenesisError)?.reason == rejection.reason, Comment(rawValue: rejection.name))
        }
    }
    
    // MARK: - accountId
    
    @Test
    func accountIDSpellingRules() throws {
        #expect(AccountID.canonicalPattern == vectors.accountId.pattern)
        #expect(AccountID.prefix == vectors.accountId.prefix)
        #expect(Int(AccountID.formatVersion) == vectors.accountId.formatVersion)
        #expect(Int(AccountID.classGenesis) == vectors.accountId.rootClassGenesis)
        #expect(Int(AccountID.classBootstrap) == vectors.accountId.rootClassBootstrap)
        #expect(AccountID.rawLength == vectors.accountId.rawLength)
        #expect(AccountID.encodedLength == vectors.accountId.encodedLength)
        #expect(AccountID.length == vectors.accountId.totalLength)
        
        // The last character holds three unused bits, so only these four can end a well-formed id.
        for vector in vectors.accountGenesis {
            let last = try #require(vector.accountId.last).description
            #expect(vectors.accountId.allowedFinalCharacters.contains(last), Comment(rawValue: vector.name))
        }
    }
    
    @Test
    func accountIDRoundTripsThroughParse() throws {
        for vector in vectors.accountGenesis {
            let parsed = try AccountID.parse(vector.accountId)
            #expect(parsed.value == vector.accountId, Comment(rawValue: vector.name))
            #expect(parsed.rawBytes.count == AccountID.rawLength, Comment(rawValue: vector.name))
            #expect(parsed.rootClass == AccountID.classGenesis, Comment(rawValue: vector.name))
            // Deriving from the same bytes gives the same id, and the raw bytes agree.
            let derived = try AccountGenesis.decode(GenesisHex.bytes(vector.canonicalHex)).accountID()
            #expect(derived.rawBytes == parsed.rawBytes, Comment(rawValue: vector.name))
        }
    }
    
    @Test
    func accountIDRejections() throws {
        for rejection in vectors.rejections.accountId {
            let value = try #require(rejection.value)
            let error = try #require(throws: (any Error).self, Comment(rawValue: rejection.name)) {
                try AccountID.parse(value)
            }
            #expect((error as? AccountGenesisError)?.reason == rejection.reason, Comment(rawValue: rejection.name))
        }
    }
    
    // MARK: - Attach proof
    
    @Test
    func attachProofPreimageMatchesTheVector() throws {
        let vector = vectors.attachProof
        #expect(GenesisProofs.attachProofDomain == vector.domain)
        #expect(GenesisProofs.attachProofDomain.utf8.count == vector.domainLength)
        #expect(GenesisProofs.attachPreimageLength == vector.preimageLength)
        
        let accountID = try AccountID.parse(vector.accountId)
        #expect(GenesisHex.string(accountID.rawBytes) == vector.accountIdRawHex)
        
        let preimage = try GenesisProofs.attachProofPreimage(challenge: GenesisHex.bytes(vector.challengeHex),
                                                             accountID: accountID)
        #expect(GenesisHex.string(preimage) == vector.preimageHex)
        #expect(preimage.count == vector.preimageLength)
    }
    
    @Test
    func publishedAttachProofVerifies() throws {
        let vector = vectors.attachProof
        let authority = try #require(vectors.accountGenesis.first)
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: Data(GenesisHex.bytes(authority.authorityPublicKeyHex)))
        let preimage = try GenesisProofs.attachProofPreimage(challenge: GenesisHex.bytes(vector.challengeHex),
                                                             accountID: AccountID.parse(vector.accountId))
        let signature = try #require(Data(base64Encoded: vector.signatureB64))
        #expect(publicKey.isValidSignature(signature, for: Data(preimage)))
    }
    
    @Test
    func attachProofRejectsAWrongLengthChallenge() throws {
        let accountID = try AccountID.parse(vectors.attachProof.accountId)
        let error = try #require(throws: (any Error).self) {
            try GenesisProofs.attachProofPreimage(challenge: [UInt8](repeating: 0, count: 31),
                                                  accountID: accountID)
        }
        #expect((error as? AccountGenesisError)?.reason == AccountGenesisError.wrongLength.reason)
    }
    
    // MARK: - Keys this device generates
    
    @Test
    func aGenesisBuiltFromFreshKeysRoundTrips() throws {
        let authority = Curve25519.Signing.PrivateKey()
        let recovery = Curve25519.Signing.PrivateKey()
        var entropy = [UInt8](repeating: 0, count: AccountGenesis.entropyLength)
        #expect(SecRandomCopyBytes(kSecRandomDefault, entropy.count, &entropy) == errSecSuccess)
        
        let canonical = try AccountGenesis.encode(authorityPublicKey: [UInt8](authority.publicKey.rawRepresentation),
                                                  recoveryAuthorityPublicKey: [UInt8](recovery.publicKey.rawRepresentation),
                                                  entropy: entropy)
        let genesis = try AccountGenesis.decode(canonical)
        let accountID = try genesis.accountID()
        
        #expect(accountID.value.count == AccountID.length)
        #expect(accountID.value.range(of: AccountID.canonicalPattern, options: .regularExpression) != nil)
        #expect(try AccountID.parse(accountID.value) == accountID)
        
        // A proof this client makes verifies under the key the genesis commits, which is what
        // identity-service checks on registration.
        let signature = try authority.signature(for: Data(GenesisProofs.genesisProofPreimage(canonicalBytes: canonical)))
        #expect(authority.publicKey.isValidSignature(signature,
                                                     for: Data(GenesisProofs.genesisProofPreimage(canonicalBytes: canonical))))
    }
    
    @Test
    func base32RejectsNonCanonicalSpellings() throws {
        // Uppercase, padding and a character outside the alphabet are all refused, because each would
        // give one byte string a second spelling.
        #expect(throws: (any Error).self) {
            try GuaBase32.decode("AAAA")
        }
        #expect(throws: (any Error).self) {
            try GuaBase32.decode("aaaa====")
        }
        #expect(throws: (any Error).self) {
            try GuaBase32.decode("aaa1")
        }
        // 1, 3 and 6 left-over characters cannot come out of any byte string.
        #expect(throws: (any Error).self) {
            try GuaBase32.decode("a")
        }
        #expect(throws: (any Error).self) {
            try GuaBase32.decode("aaa")
        }
        #expect(throws: (any Error).self) {
            try GuaBase32.decode("aaaaaa")
        }
        // Non-zero trailing bits.
        #expect(throws: (any Error).self) {
            try GuaBase32.decode("ab")
        }
        #expect(try GuaBase32.decode("aa") == [0])
    }
}

// MARK: - Vectors

private enum GenesisHex {
    static func bytes(_ hex: String) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            if let value = UInt8(hex[index..<next], radix: 16) {
                out.append(value)
            }
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
