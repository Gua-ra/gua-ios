//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import CryptoKit
@testable import ElementX
import XCTest

@MainActor
final class AccountGenesisServiceTests: XCTestCase {
    private var registrar: GenesisRegistrarStub!
    private var keyStore: AccountAuthorityKeyStoreStub!
    private var appSettings: AppSettings!
    private var service: AccountGenesisService!

    override func setUp() {
        registrar = GenesisRegistrarStub()
        keyStore = AccountAuthorityKeyStoreStub()
        appSettings = AppSettings()
        appSettings.guaAccountGenesisEnabled = false
        service = AccountGenesisService(identityServiceClient: registrar,
                                        keyStore: keyStore,
                                        appSettings: appSettings)
    }

    override func tearDown() {
        appSettings.guaAccountGenesisEnabled = false
    }

    // MARK: - The flag

    func testTheFlagIsOffByDefault() {
        XCTAssertFalse(AppSettings().guaAccountGenesisEnabled,
                       "Account genesis must stay off until it is deliberately turned on.")
        XCTAssertFalse(service.isEnabled)
    }

    func testWithTheFlagOffNothingIsGeneratedStoredOrSent() async throws {
        let outcome = try await service.registerGenesis()

        XCTAssertEqual(outcome, .disabled)
        XCTAssertEqual(registrar.callCount, 0, "No registration call may be made while the flag is off.")
        XCTAssertTrue(keyStore.stored.isEmpty, "No key may be created or stored while the flag is off.")
        XCTAssertNil(registrar.receivedGenesis)
    }

    // MARK: - Registration

    func testRegistrationSendsCanonicalBytesAndAVerifiableProof() async throws {
        appSettings.guaAccountGenesisEnabled = true

        let outcome = try await service.registerGenesis()

        guard case .registered(let pending) = outcome else {
            return XCTFail("Expected the genesis to be registered, got \(outcome).")
        }
        XCTAssertEqual(pending.attachHandle, registrar.handle)

        // What went on the wire decodes under this client's own strict decoder, and re-derives the
        // accountId the service reported.
        let genesisBytes = try XCTUnwrap(try GuaBase64URL.decode(XCTUnwrap(registrar.receivedGenesis)))
        let genesis = try AccountGenesis.decode(genesisBytes)
        XCTAssertEqual(try genesis.accountID().value, pending.accountID.value)
        XCTAssertEqual(genesisBytes.count, AccountGenesis.length)
        XCTAssertEqual(genesis.recoveryFrameworkID, AccountGenesis.recoveryFrameworkCommittedKey)

        // The proof verifies under the key committed inside those bytes, which is exactly what
        // identity-service checks, and the two committed keys are distinct.
        let proof = try XCTUnwrap(try GuaBase64URL.decode(XCTUnwrap(registrar.receivedProof)))
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: Data(genesis.authorityPublicKey))
        let preimage = GenesisProofs.genesisProofPreimage(canonicalBytes: genesisBytes)
        XCTAssertTrue(publicKey.isValidSignature(Data(proof), for: Data(preimage)))
        XCTAssertNotEqual(genesis.authorityPublicKey, genesis.recoveryAuthorityPublicKey)

        // The authority key is kept, under the accountId, for the attach step.
        XCTAssertNotNil(keyStore.stored[pending.accountID.value])
    }

    func testADeploymentWithoutGenesisFallsBackSilently() async throws {
        appSettings.guaAccountGenesisEnabled = true
        registrar.errorToThrow = IdentityServiceError.genesisUnavailable

        let outcome = try await service.registerGenesis()

        XCTAssertEqual(outcome, .notSupportedByDeployment)
        // Nothing is left behind for a signup that will take the bootstrap path.
        XCTAssertTrue(keyStore.stored.isEmpty)
    }

    func testAFailedRegistrationThrowsAndLeavesNoKeys() async throws {
        appSettings.guaAccountGenesisEnabled = true
        registrar.errorToThrow = IdentityServiceError.server(status: 500, message: nil)

        do {
            _ = try await service.registerGenesis()
            XCTFail("A failed registration must not be reported as a success.")
        } catch AccountGenesisServiceError.registrationFailed {
            XCTAssertTrue(keyStore.stored.isEmpty)
        }
    }

    func testAnAccountIDTheServerDisagreesWithIsRefused() async throws {
        appSettings.guaAccountGenesisEnabled = true
        registrar.accountIDOverride = "ga1aeatmvszaxoxcnsrkzpzbvaust6jcdhcapmia7snhqrspmukdojzkgq"

        do {
            _ = try await service.registerGenesis()
            XCTFail("An accountId that does not match the one derived on device must be refused.")
        } catch AccountGenesisServiceError.registrationFailed {
            XCTAssertTrue(keyStore.stored.isEmpty)
        }
    }

    // MARK: - The login hint

    func testTheLoginHintUsesTheReservedGrammar() async throws {
        appSettings.guaAccountGenesisEnabled = true
        registrar.handle = "dGVzdC1oYW5kbGUtdGhhdC1pcy1sb25nLWVub3VnaA"

        guard case .registered(let pending) = try await service.registerGenesis() else {
            return XCTFail("Expected the genesis to be registered.")
        }

        let hint = service.loginHint(phoneNumber: "+5511999999999", pending: pending)

        XCTAssertEqual(hint, "gua:phone=+5511999999999;genesis=dGVzdC1oYW5kbGUtdGhhdC1pcy1sb25nLWVub3VnaA")
        // The bare reserved value for passkey-first entry keeps its own meaning; the prefixed grammar
        // must never collide with it.
        XCTAssertNotEqual(hint, AuthenticationService.passkeyLoginHint)
        XCTAssertTrue(hint.hasPrefix("gua:"))
    }

    // MARK: - The attach proof

    func testTheAttachProofMatchesTheSpecifiedPreimageAndVerifies() async throws {
        appSettings.guaAccountGenesisEnabled = true
        guard case .registered(let pending) = try await service.registerGenesis() else {
            return XCTFail("Expected the genesis to be registered.")
        }

        let challengeBytes = [UInt8](0..<32)
        let challenge = GuaBase64URL.encode(challengeBytes)

        let proof = try service.attachProof(challenge: challenge, for: pending)

        let preimage = try GenesisProofs.attachProofPreimage(challenge: challengeBytes, accountID: pending.accountID)
        XCTAssertEqual(preimage.count, GenesisProofs.attachPreimageLength)
        XCTAssertEqual(Array(preimage.prefix(GenesisProofs.attachProofDomain.utf8.count)),
                       Array(GenesisProofs.attachProofDomain.utf8))
        XCTAssertEqual(Array(preimage.suffix(AccountID.rawLength)), pending.accountID.rawBytes)

        let keyPair = try XCTUnwrap(keyStore.stored[pending.accountID.value])
        let signature = try XCTUnwrap(GuaBase64URL.decode(proof))
        XCTAssertTrue(keyPair.authority.publicKey.isValidSignature(Data(signature), for: Data(preimage)))
    }

    func testTheAttachProofFailsWhenTheAuthorityKeyIsGone() async throws {
        appSettings.guaAccountGenesisEnabled = true
        guard case .registered(let pending) = try await service.registerGenesis() else {
            return XCTFail("Expected the genesis to be registered.")
        }
        keyStore.removeKeys(forAccountID: pending.accountID.value)

        XCTAssertThrowsError(try service.attachProof(challenge: GuaBase64URL.encode([UInt8](repeating: 7, count: 32)),
                                                     for: pending)) { error in
            // Failing the signup is the point: a device that registered a genesis and then creates an
            // account without it is the silent bootstrap ADM-008 decision 6 forbids.
            guard case AccountGenesisServiceError.keyUnavailable = error else {
                return XCTFail("Expected keyUnavailable, got \(error).")
            }
        }
    }

    func testTheAttachProofRejectsAMalformedChallenge() async throws {
        appSettings.guaAccountGenesisEnabled = true
        guard case .registered(let pending) = try await service.registerGenesis() else {
            return XCTFail("Expected the genesis to be registered.")
        }

        for challenge in ["", "not base64url!!", GuaBase64URL.encode([UInt8](repeating: 0, count: 31))] {
            XCTAssertThrowsError(try service.attachProof(challenge: challenge, for: pending), challenge) { error in
                guard case AccountGenesisServiceError.malformedChallenge = error else {
                    return XCTFail("Expected malformedChallenge for \(challenge), got \(error).")
                }
            }
        }
    }

    func testDiscardingASignupRemovesItsKeys() async throws {
        appSettings.guaAccountGenesisEnabled = true
        guard case .registered(let pending) = try await service.registerGenesis() else {
            return XCTFail("Expected the genesis to be registered.")
        }
        XCTAssertNotNil(keyStore.stored[pending.accountID.value])

        service.discard(pending)

        XCTAssertNil(keyStore.stored[pending.accountID.value])
    }
}

// MARK: - Stubs

/// Echoes back the accountId derived from the bytes it was handed, the way identity-service does, so a
/// test can assert on what the client actually put on the wire.
private final class GenesisRegistrarStub: AccountGenesisRegistering, @unchecked Sendable {
    var handle = "c3R1Yi1hdHRhY2gtaGFuZGxlLWZvci10ZXN0cw"
    var errorToThrow: Error?
    var accountIDOverride: String?
    private(set) var receivedGenesis: String?
    private(set) var receivedProof: String?
    private(set) var callCount = 0

    func registerAccountGenesis(genesis: String, proof: String) async throws -> AccountGenesisRegistrationResponse {
        callCount += 1
        receivedGenesis = genesis
        receivedProof = proof
        if let errorToThrow { throw errorToThrow }

        guard let bytes = GuaBase64URL.decode(genesis) else { throw AccountGenesisError.badBase32 }
        let accountID = try AccountGenesis.decode(bytes).accountID()
        return AccountGenesisRegistrationResponse(accountID: accountIDOverride ?? accountID.value,
                                                  attachHandle: handle,
                                                  expiresAt: Date().addingTimeInterval(1800))
    }
}

@MainActor
private final class AccountAuthorityKeyStoreStub: AccountAuthorityKeyStoreProtocol {
    var stored: [String: AccountAuthorityKeyPair] = [:]

    func generateKeyPair() -> AccountAuthorityKeyPair {
        AccountAuthorityKeyPair(authority: Curve25519.Signing.PrivateKey(),
                                recovery: Curve25519.Signing.PrivateKey())
    }

    func persist(_ keyPair: AccountAuthorityKeyPair, forAccountID accountID: String) throws {
        stored[accountID] = keyPair
    }

    func authorityKey(forAccountID accountID: String) throws -> Curve25519.Signing.PrivateKey {
        guard let keyPair = stored[accountID] else { throw AccountAuthorityKeyStoreError.keyMissing }
        return keyPair.authority
    }

    func removeKeys(forAccountID accountID: String) {
        stored[accountID] = nil
    }
}
