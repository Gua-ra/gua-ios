//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import CryptoKit
@testable import ElementX
import Foundation
import Testing

@MainActor
final class AccountGenesisServiceTests {
    private var registrar: GenesisRegistrarStub!
    private var keyStore: AccountAuthorityKeyStoreStub!
    private var appSettings: AppSettings!
    private var service: AccountGenesisService!
    
    init() {
        registrar = GenesisRegistrarStub()
        keyStore = AccountAuthorityKeyStoreStub()
        appSettings = AppSettings.volatile()
        appSettings.guaAccountGenesisEnabled = false
        service = AccountGenesisService(identityServiceClient: registrar,
                                        keyStore: keyStore,
                                        appSettings: appSettings)
    }
    
    isolated deinit {
        appSettings.guaAccountGenesisEnabled = false
    }
    
    // MARK: - The flag
    
    @Test
    func theFlagIsOffByDefault() {
        #expect(!AppSettings.volatile().guaAccountGenesisEnabled, "Account genesis must stay off until it is deliberately turned on.")
        #expect(!service.isEnabled)
    }
    
    @Test
    func withTheFlagOffNothingIsGeneratedStoredOrSent() async throws {
        let outcome = try await service.registerGenesis()
        
        #expect(outcome == .disabled)
        #expect(registrar.callCount == 0, "No registration call may be made while the flag is off.")
        #expect(keyStore.stored.isEmpty, "No key may be created or stored while the flag is off.")
        #expect(registrar.receivedGenesis == nil)
    }
    
    // MARK: - Registration
    
    @Test
    func registrationSendsCanonicalBytesAndAVerifiableProof() async throws {
        appSettings.guaAccountGenesisEnabled = true
        
        let outcome = try await service.registerGenesis()
        
        guard case .registered(let pending) = outcome else {
            Issue.record("Expected the genesis to be registered, got \(outcome).")
            return
        }
        #expect(pending.attachHandle == registrar.handle)
        
        // What went on the wire decodes under this client's own strict decoder, and re-derives the
        // accountId the service reported.
        let receivedGenesis = try #require(registrar.receivedGenesis)
        let genesisBytes = try #require(GuaBase64URL.decode(receivedGenesis))
        let genesis = try AccountGenesis.decode(genesisBytes)
        #expect(try genesis.accountID().value == pending.accountID.value)
        #expect(genesisBytes.count == AccountGenesis.length)
        #expect(genesis.recoveryFrameworkID == AccountGenesis.recoveryFrameworkCommittedKey)
        
        // The proof verifies under the key committed inside those bytes, which is exactly what
        // identity-service checks, and the two committed keys are distinct.
        let receivedProof = try #require(registrar.receivedProof)
        let proof = try #require(GuaBase64URL.decode(receivedProof))
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: Data(genesis.authorityPublicKey))
        let preimage = GenesisProofs.genesisProofPreimage(canonicalBytes: genesisBytes)
        #expect(publicKey.isValidSignature(Data(proof), for: Data(preimage)))
        #expect(genesis.authorityPublicKey != genesis.recoveryAuthorityPublicKey)
        
        // The authority key is kept, under the accountId, for the attach step.
        #expect(keyStore.stored[pending.accountID.value] != nil)
    }
    
    @Test
    func aDeploymentWithoutGenesisFallsBackSilently() async throws {
        appSettings.guaAccountGenesisEnabled = true
        registrar.errorToThrow = IdentityServiceError.genesisUnavailable
        
        let outcome = try await service.registerGenesis()
        
        #expect(outcome == .notSupportedByDeployment)
        // Nothing is left behind for a signup that will take the bootstrap path.
        #expect(keyStore.stored.isEmpty)
    }
    
    @Test
    func aDeploymentThatDeclinesToIssueFallsBackSilently() async throws {
        appSettings.guaAccountGenesisEnabled = true
        registrar.errorToThrow = IdentityServiceError.genesisIssuanceNotPermitted
        
        let outcome = try await service.registerGenesis()
        
        // 403 is the deployment declining to issue under this recovery framework, which is another way
        // of saying no handle exists to present. Failing the signup here would stop account creation on
        // every deployment that has genesis on without issuance permitted, which is the documented
        // default. The Android client reads 403 and 503 identically for the same reason.
        #expect(outcome == .notSupportedByDeployment)
        #expect(keyStore.stored.isEmpty)
    }
    
    @Test
    func aFailedRegistrationThrowsAndLeavesNoKeys() async throws {
        appSettings.guaAccountGenesisEnabled = true
        registrar.errorToThrow = IdentityServiceError.server(status: 500, message: nil)
        
        do {
            _ = try await service.registerGenesis()
            Issue.record("A failed registration must not be reported as a success.")
        } catch AccountGenesisServiceError.registrationFailed {
            #expect(keyStore.stored.isEmpty)
        }
    }
    
    @Test
    func anAccountIDTheServerDisagreesWithIsRefused() async throws {
        appSettings.guaAccountGenesisEnabled = true
        registrar.accountIDOverride = "ga1aeatmvszaxoxcnsrkzpzbvaust6jcdhcapmia7snhqrspmukdojzkgq"
        
        do {
            _ = try await service.registerGenesis()
            Issue.record("An accountId that does not match the one derived on device must be refused.")
        } catch AccountGenesisServiceError.registrationFailed {
            #expect(keyStore.stored.isEmpty)
        }
    }
    
    // MARK: - The attach handle
    
    @Test
    func theAttachHandleAlphabetMatchesTheServerParser() {
        #expect(PendingAccountGenesis.isValidAttachHandle(String(repeating: "a", count: 16)))
        #expect(PendingAccountGenesis.isValidAttachHandle(String(repeating: "a", count: 128)))
        #expect(PendingAccountGenesis.isValidAttachHandle("AZaz09-_AZaz09-_"))
        
        #expect(!PendingAccountGenesis.isValidAttachHandle(String(repeating: "a", count: 15)))
        #expect(!PendingAccountGenesis.isValidAttachHandle(String(repeating: "a", count: 129)))
        #expect(!PendingAccountGenesis.isValidAttachHandle("padded+handle/with=="))
        #expect(!PendingAccountGenesis.isValidAttachHandle("handle-with-a-\u{e7}-in-it"))
        #expect(!PendingAccountGenesis.isValidAttachHandle("handle with spaces!!"))
    }
    
    @Test
    func aMalformedAttachHandleIsRefusedAndLeavesNoKeys() async throws {
        appSettings.guaAccountGenesisEnabled = true
        
        for handle in ["", "too-short", "handle with spaces!!", "semicolon;and=equals;in-it", String(repeating: "a", count: 129)] {
            keyStore.stored.removeAll()
            registrar.handle = handle
            
            do {
                _ = try await service.registerGenesis()
                Issue.record("A handle the server's own parser would refuse must never reach a login hint: \(handle)")
            } catch AccountGenesisServiceError.malformedAttachHandle {
                #expect(keyStore.stored.isEmpty, "No keys may survive a registration this client refused.")
            }
        }
    }
    
    @Test
    func aHandleThatArrivesOutsideItsWindowIsRefused() async throws {
        appSettings.guaAccountGenesisEnabled = true
        registrar.expiresAt = Date().addingTimeInterval(-1)
        
        do {
            _ = try await service.registerGenesis()
            Issue.record("A handle that is already outside its window must not be presented.")
        } catch AccountGenesisServiceError.handleExpired {
            #expect(keyStore.stored.isEmpty)
        }
    }
    
    // MARK: - The login hint
    
    @Test
    func theLoginHintUsesTheReservedGrammar() async throws {
        appSettings.guaAccountGenesisEnabled = true
        registrar.handle = "dGVzdC1oYW5kbGUtdGhhdC1pcy1sb25nLWVub3VnaA"
        
        guard case .registered(let pending) = try await service.registerGenesis() else {
            Issue.record("Expected the genesis to be registered.")
            return
        }
        
        let hint = service.loginHint(phoneNumber: "+5511999999999", pending: pending)
        
        #expect(hint == "gua:phone=+5511999999999;genesis=dGVzdC1oYW5kbGUtdGhhdC1pcy1sb25nLWVub3VnaA")
        // The bare reserved value for passkey-first entry keeps its own meaning; the prefixed grammar
        // must never collide with it.
        #expect(hint != AuthenticationService.passkeyLoginHint)
        #expect(hint.hasPrefix("gua:"))
    }
    
    // MARK: - The attach proof
    
    @Test
    func theAttachProofMatchesTheSpecifiedPreimageAndVerifies() async throws {
        appSettings.guaAccountGenesisEnabled = true
        guard case .registered(let pending) = try await service.registerGenesis() else {
            Issue.record("Expected the genesis to be registered.")
            return
        }
        
        let challengeBytes = [UInt8](0..<32)
        let challenge = GuaBase64URL.encode(challengeBytes)
        
        let proof = try service.attachProof(challenge: challenge, for: pending)
        
        let preimage = try GenesisProofs.attachProofPreimage(challenge: challengeBytes, accountID: pending.accountID)
        #expect(preimage.count == GenesisProofs.attachPreimageLength)
        #expect(Array(preimage.prefix(GenesisProofs.attachProofDomain.utf8.count)) == Array(GenesisProofs.attachProofDomain.utf8))
        #expect(Array(preimage.suffix(AccountID.rawLength)) == pending.accountID.rawBytes)
        
        let keyPair = try #require(keyStore.stored[pending.accountID.value])
        let signature = try #require(GuaBase64URL.decode(proof))
        #expect(keyPair.authority.publicKey.isValidSignature(Data(signature), for: Data(preimage)))
    }
    
    @Test
    func theAttachProofFailsWhenTheAuthorityKeyIsGone() async throws {
        appSettings.guaAccountGenesisEnabled = true
        guard case .registered(let pending) = try await service.registerGenesis() else {
            Issue.record("Expected the genesis to be registered.")
            return
        }
        keyStore.removeKeys(forAccountID: pending.accountID.value)
        
        let error = try #require(throws: (any Error).self) {
            try service.attachProof(challenge: GuaBase64URL.encode([UInt8](repeating: 7, count: 32)),
                                    for: pending)
        }
        // Failing the signup is the point: a device that registered a genesis and then creates an
        // account without it is the silent bootstrap ADM-008 decision 6 forbids.
        guard case AccountGenesisServiceError.keyUnavailable = error else {
            Issue.record("Expected keyUnavailable, got \(error).")
            return
        }
    }
    
    @Test
    func theAttachProofRejectsAMalformedChallenge() async throws {
        appSettings.guaAccountGenesisEnabled = true
        guard case .registered(let pending) = try await service.registerGenesis() else {
            Issue.record("Expected the genesis to be registered.")
            return
        }
        
        for challenge in ["", "not base64url!!", GuaBase64URL.encode([UInt8](repeating: 0, count: 31))] {
            let error = try #require(throws: (any Error).self, Comment(rawValue: challenge)) {
                try service.attachProof(challenge: challenge, for: pending)
            }
            guard case AccountGenesisServiceError.malformedChallenge = error else {
                Issue.record("Expected malformedChallenge for \(challenge), got \(error).")
                return
            }
        }
    }
    
    @Test
    func theAttachProofIsRefusedOnceTheWindowHasClosed() async throws {
        appSettings.guaAccountGenesisEnabled = true
        guard case .registered(let pending) = try await service.registerGenesis() else {
            Issue.record("Expected the genesis to be registered.")
            return
        }
        let expired = PendingAccountGenesis(accountID: pending.accountID,
                                            attachHandle: pending.attachHandle,
                                            expiresAt: Date().addingTimeInterval(-1))
        
        let error = try #require(throws: (any Error).self) {
            try service.attachProof(challenge: GuaBase64URL.encode([UInt8](0..<32)),
                                    for: expired)
        }
        guard case AccountGenesisServiceError.handleExpired = error else {
            Issue.record("Expected handleExpired, got \(error).")
            return
        }
    }
    
    @Test
    func discardingASignupRemovesItsKeys() async throws {
        appSettings.guaAccountGenesisEnabled = true
        guard case .registered(let pending) = try await service.registerGenesis() else {
            Issue.record("Expected the genesis to be registered.")
            return
        }
        #expect(keyStore.stored[pending.accountID.value] != nil)
        
        service.discard(pending)
        
        #expect(keyStore.stored[pending.accountID.value] == nil)
    }
}

// MARK: - Stubs

/// Echoes back the accountId derived from the bytes it was handed, the way identity-service does, so a
/// test can assert on what the client actually put on the wire.
private final class GenesisRegistrarStub: AccountGenesisRegistering, @unchecked Sendable {
    var handle = "c3R1Yi1hdHRhY2gtaGFuZGxlLWZvci10ZXN0cw"
    var expiresAt = Date().addingTimeInterval(1800)
    var errorToThrow: Error?
    var accountIDOverride: String?
    private(set) var receivedGenesis: String?
    private(set) var receivedProof: String?
    private(set) var callCount = 0
    
    func registerAccountGenesis(genesis: String, proof: String) async throws -> AccountGenesisRegistrationResponse {
        callCount += 1
        receivedGenesis = genesis
        receivedProof = proof
        if let errorToThrow {
            throw errorToThrow
        }
        
        guard let bytes = GuaBase64URL.decode(genesis) else { throw AccountGenesisError.badBase32 }
        let accountID = try AccountGenesis.decode(bytes).accountID()
        return AccountGenesisRegistrationResponse(accountID: accountIDOverride ?? accountID.value,
                                                  attachHandle: handle,
                                                  expiresAt: expiresAt)
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
