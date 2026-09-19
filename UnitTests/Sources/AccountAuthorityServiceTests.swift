//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import CryptoKit
@testable import ElementX
import XCTest

@MainActor
final class AccountAuthorityServiceTests: XCTestCase {
    private var client: AuthorityRequesterStub!
    private var keyStore: AuthorityKeyStoreStub!
    private var appSettings: AppSettings!
    private var service: AccountAuthorityService!

    private var accountID: AccountID!

    override func setUpWithError() throws {
        accountID = try AccountID.derive(rootClass: AccountID.classBootstrap,
                                         canonicalBytes: [UInt8]("account-under-test".utf8))
        client = AuthorityRequesterStub()
        keyStore = AuthorityKeyStoreStub()
        appSettings = AppSettings()
        appSettings.guaAccountAuthorityEnabled = false
        service = AccountAuthorityService(client: client,
                                          keyStore: keyStore,
                                          appSettings: appSettings,
                                          deviceLabel: "iPhone")
    }

    override func tearDown() {
        appSettings.guaAccountAuthorityEnabled = false
    }

    // MARK: - The flag

    func testTheFlagIsOffByDefault() {
        XCTAssertFalse(AppSettings().guaAccountAuthorityEnabled,
                       "The account authority chain must stay off until it is deliberately turned on.")
        XCTAssertFalse(service.isEnabled)
    }

    func testWithTheFlagOffNothingIsGeneratedStoredOrSent() async {
        await assertThrowsDisabled { try await self.service.state(accessToken: "token") }
        await assertThrowsDisabled {
            try await self.service.prepareAdoption(accessToken: "token", accountID: self.accountID, stepUp: .pin("123456"))
        }
        await assertThrowsDisabled { try await self.service.liveApprovals(accessToken: "token") }

        XCTAssertEqual(client.callCount, 0, "No request may be made while the flag is off.")
        XCTAssertTrue(keyStore.stored.isEmpty, "No key may be created or stored while the flag is off.")
    }

    // MARK: - Adoption

    func testAdoptionSignsTheChallengeInsideTheRecordUnderTheKeyTheRecordCommits() async throws {
        appSettings.guaAccountAuthorityEnabled = true

        let prepared = try await service.prepareAdoption(accessToken: "token",
                                                         accountID: accountID,
                                                         stepUp: .pin("123456"))

        XCTAssertEqual(client.challengeRequests.count, 1)
        XCTAssertEqual(client.challengeRequests.first?.purpose, .adopt)
        XCTAssertEqual(client.challengeRequests.first?.stepUp, .pin("123456"))

        // What was built decodes under this client's own strict rules.
        let bytes = try XCTUnwrap(GuaBase64URL.decode(prepared.record))
        XCTAssertNoThrow(try AuthorityRecord.validate(bytes))
        XCTAssertEqual(bytes.count, 177)
        XCTAssertEqual(Array(bytes[6..<40]), accountID.rawBytes)

        // And the signature verifies against the preimage the server rebuilds: the magic, the challenge
        // it minted, and these exact bytes.
        let challenge = try XCTUnwrap(GuaBase64URL.decode(prepared.challenge))
        let preimage = try AuthorityProofs.recordPreimage(type: .adoptRoot, challenge: challenge, canonicalBytes: bytes)
        let deviceKey = try Curve25519.Signing.PublicKey(rawRepresentation: Data(Array(bytes[80..<112])))
        let signature = try XCTUnwrap(GuaBase64URL.decode(prepared.signature))
        XCTAssertTrue(deviceKey.isValidSignature(Data(signature), for: Data(preimage)))
    }

    func testAdoptionCommitsTwoDistinctKeysAndKeepsBothOnThisDevice() async throws {
        appSettings.guaAccountAuthorityEnabled = true

        let prepared = try await service.prepareAdoption(accessToken: "token",
                                                         accountID: accountID,
                                                         stepUp: .pin("123456"))

        let bytes = try XCTUnwrap(GuaBase64URL.decode(prepared.record))
        XCTAssertNotEqual(Array(bytes[80..<112]), Array(bytes[113..<145]))

        // Stored before the submission, exactly as the genesis registration does it: an adoption that is
        // accepted while its reply is lost still has its key on this device.
        let stored = try XCTUnwrap(keyStore.stored[accountID.value])
        XCTAssertEqual([UInt8](stored.authority.publicKey.rawRepresentation), Array(bytes[80..<112]))
        XCTAssertEqual([UInt8](stored.recovery.publicKey.rawRepresentation), Array(bytes[113..<145]))
    }

    func testTheRecoveryArtifactIsTheCommittedRecoveryKeyAndIsShownOnce() async throws {
        appSettings.guaAccountAuthorityEnabled = true

        let prepared = try await service.prepareAdoption(accessToken: "token",
                                                         accountID: accountID,
                                                         stepUp: .pin("123456"))

        let artifact = try XCTUnwrap(prepared.recoveryArtifact)
        let stored = try XCTUnwrap(keyStore.stored[accountID.value])
        let decoded = try GuaBase32.decode(artifact.replacingOccurrences(of: " ", with: ""))
        XCTAssertEqual(decoded, [UInt8](stored.recovery.rawRepresentation))

        prepared.confirmArtifactStored()
        XCTAssertNil(prepared.recoveryArtifact, "Shown once means the object stops holding it.")
    }

    func testAdoptionIsUnreachableWithoutTheArtifactConfirmation() async throws {
        appSettings.guaAccountAuthorityEnabled = true

        let prepared = try await service.prepareAdoption(accessToken: "token",
                                                         accountID: accountID,
                                                         stepUp: .pin("123456"))
        XCTAssertFalse(prepared.isArtifactConfirmed)

        do {
            _ = try await service.submitAdoption(accessToken: "token", prepared: prepared)
            XCTFail("An unconfirmed adoption must not be submitted.")
        } catch {
            XCTAssertEqual(error as? AccountAuthorityServiceError, .artifactUnconfirmed)
        }
        XCTAssertEqual(client.adoptions.count, 0, "The request must never be made, not merely refused by the server.")

        prepared.confirmArtifactStored()
        _ = try await service.submitAdoption(accessToken: "token", prepared: prepared)

        XCTAssertEqual(client.adoptions.count, 1)
        XCTAssertEqual(client.adoptions.first?.recoveryArtifactConfirmed, true)
        XCTAssertEqual(client.adoptions.first?.record, prepared.record)
        XCTAssertEqual(client.adoptions.first?.challenge, prepared.challenge,
                       "The challenge travels back: the server holds only its hash and cannot rebuild the preimage without it.")
    }

    func testARefusedAdoptionDropsItsKeysAndALostReplyKeepsThem() async throws {
        appSettings.guaAccountAuthorityEnabled = true

        let refused = try await service.prepareAdoption(accessToken: "token", accountID: accountID, stepUp: .pin("123456"))
        refused.confirmArtifactStored()
        client.submissionError = IdentityServiceError.authority(.positionRefused)
        _ = try? await service.submitAdoption(accessToken: "token", prepared: refused)
        XCTAssertNil(keyStore.stored[accountID.value],
                     "A refusal the server made up its mind about leaves keys no record will ever name.")

        let lost = try await service.prepareAdoption(accessToken: "token", accountID: accountID, stepUp: .pin("123456"))
        lost.confirmArtifactStored()
        client.submissionError = IdentityServiceError.transport(URLError(.timedOut))
        _ = try? await service.submitAdoption(accessToken: "token", prepared: lost)
        XCTAssertNotNil(keyStore.stored[accountID.value],
                        "A lost reply may well have been accepted, so its keys stay.")
    }

    func testAKeyStoreThatRefusesEndsTheAdoption() async throws {
        appSettings.guaAccountAuthorityEnabled = true
        keyStore.refusesToPersist = true

        do {
            _ = try await service.prepareAdoption(accessToken: "token", accountID: accountID, stepUp: .pin("123456"))
            XCTFail("An adoption whose key could not be stored must not go on to be submitted.")
        } catch {
            // Carrying on would commit a key this device cannot read back, which is an account rooted on
            // nothing, permanently.
            XCTAssertEqual(error as? AccountAuthorityServiceError, .keyUnavailable)
        }
        XCTAssertEqual(client.adoptions.count, 0)
    }

    // MARK: - Granting another device

    func testAGrantChainsOntoTheHeadAndNamesThisDeviceAsTheAuthorizingKey() async throws {
        appSettings.guaAccountAuthorityEnabled = true
        let deviceKey = Curve25519.Signing.PrivateKey()
        keyStore.stored[accountID.value] = AccountAuthorityKeyPair(authority: deviceKey,
                                                                   recovery: Curve25519.Signing.PrivateKey())
        let headHash = String(repeating: "ab", count: 32)
        let granteeKey = [UInt8](Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)

        _ = try await service.signDeviceGrant(accessToken: "token",
                                              state: chainState(headSeq: 4, headHash: headHash),
                                              granteeKey: granteeKey,
                                              label: "iPad",
                                              stepUp: .pin("123456"))

        let submitted = try XCTUnwrap(client.grants.first)
        let bytes = try XCTUnwrap(GuaBase64URL.decode(submitted.record))
        XCTAssertEqual(Array(bytes[0..<4]), Array("GUAD".utf8))
        XCTAssertEqual(Array(bytes[40..<72]), AuthorityRecord.hashBytes(fromHex: headHash))
        XCTAssertEqual(Array(bytes[72..<80]), [0, 0, 0, 0, 0, 0, 0, 5], "A record takes exactly one seq more than the head.")
        XCTAssertEqual(Array(bytes[80..<112]), granteeKey)
        XCTAssertEqual(Array(bytes[129..<161]), [UInt8](deviceKey.publicKey.rawRepresentation))
        XCTAssertEqual(client.challengeRequests.first?.purpose, .grant)

        let challenge = try XCTUnwrap(GuaBase64URL.decode(submitted.challenge))
        let preimage = try AuthorityProofs.recordPreimage(type: .deviceGrant, challenge: challenge, canonicalBytes: bytes)
        let signature = try XCTUnwrap(GuaBase64URL.decode(submitted.signature))
        XCTAssertTrue(deviceKey.publicKey.isValidSignature(Data(signature), for: Data(preimage)))
    }

    func testADeviceHoldingNoAuthorityKeySignsNothing() async throws {
        appSettings.guaAccountAuthorityEnabled = true

        do {
            _ = try await service.signDeviceGrant(accessToken: "token",
                                                  state: chainState(headSeq: 1, headHash: String(repeating: "0", count: 64)),
                                                  granteeKey: [UInt8](Curve25519.Signing.PrivateKey().publicKey.rawRepresentation),
                                                  label: "iPad",
                                                  stepUp: .pin("123456"))
            XCTFail("A device with no key in the chain has nothing to sign with.")
        } catch {
            XCTAssertEqual(error as? AccountAuthorityServiceError, .notAnAuthorityDevice)
        }
        XCTAssertEqual(client.challengeRequests.count, 0, "Nothing is spent before the key is known to be here.")
    }

    // MARK: - Browser approvals

    func testAnApprovalIsSignedOverTheDomainTheAccountTheActionAndTheChallenge() async throws {
        appSettings.guaAccountAuthorityEnabled = true
        let deviceKey = Curve25519.Signing.PrivateKey()
        keyStore.stored[accountID.value] = AccountAuthorityKeyPair(authority: deviceKey,
                                                                   recovery: Curve25519.Signing.PrivateKey())
        let approvalID = [UInt8](repeating: 0x05, count: 16)
        let actionDigest = [UInt8](repeating: 0x06, count: 32)
        let challenge = [UInt8](repeating: 0x07, count: 32)
        let approval = AuthorityApproval(approvalID: GuaBase64URL.encode(approvalID),
                                         code: "AB7K",
                                         action: "authority.device.grant",
                                         actionDigest: GuaBase64URL.encode(actionDigest),
                                         challenge: GuaBase64URL.encode(challenge),
                                         expiresAt: Date().addingTimeInterval(600))

        try await service.signApproval(accessToken: "token",
                                       approval: approval,
                                       state: chainState(headSeq: 1, headHash: String(repeating: "0", count: 64)))

        let signed = try XCTUnwrap(client.approvalSignatures.first)
        XCTAssertEqual(signed.approvalID, approval.approvalID)
        let preimage = try AuthorityProofs.approvalPreimage(accountID: accountID,
                                                            approvalID: approvalID,
                                                            actionDigest: actionDigest,
                                                            challenge: challenge)
        let signature = try XCTUnwrap(GuaBase64URL.decode(signed.signature))
        XCTAssertTrue(deviceKey.publicKey.isValidSignature(Data(signature), for: Data(preimage)))
    }

    func testAnApprovalWithAMalformedFieldIsNotSigned() async throws {
        appSettings.guaAccountAuthorityEnabled = true
        keyStore.stored[accountID.value] = AccountAuthorityKeyPair(authority: Curve25519.Signing.PrivateKey(),
                                                                   recovery: Curve25519.Signing.PrivateKey())
        // A 31-byte challenge is not a challenge, and a signature over whatever it happened to be would
        // still be a signature by an authority key.
        let approval = AuthorityApproval(approvalID: GuaBase64URL.encode([UInt8](repeating: 0x05, count: 16)),
                                         code: "AB7K",
                                         action: "authority.device.grant",
                                         actionDigest: GuaBase64URL.encode([UInt8](repeating: 0x06, count: 32)),
                                         challenge: GuaBase64URL.encode([UInt8](repeating: 0x07, count: 31)),
                                         expiresAt: Date())

        do {
            try await service.signApproval(accessToken: "token",
                                           approval: approval,
                                           state: chainState(headSeq: 1, headHash: String(repeating: "0", count: 64)))
            XCTFail("A malformed approval must not be signed.")
        } catch {
            XCTAssertEqual(error as? AccountAuthorityServiceError, .malformedServerValue)
        }
        XCTAssertTrue(client.approvalSignatures.isEmpty)
    }

    // MARK: - Helpers

    private func chainState(headSeq: Int64, headHash: String) -> AuthorityChainState {
        AuthorityChainState(accountID: accountID,
                            accountClass: .bootstrap,
                            state: headSeq == 0 ? .bootstrap : .rooted,
                            headSeq: headSeq,
                            headHash: headHash,
                            devices: [],
                            pending: nil)
    }

    private func assertThrowsDisabled(_ work: () async throws -> some Any,
                                      file: StaticString = #filePath,
                                      line: UInt = #line) async {
        do {
            _ = try await work()
            XCTFail("Expected the service to refuse while the flag is off.", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AccountAuthorityServiceError, .disabled, file: file, line: line)
        }
    }
}

// MARK: - Stubs

@MainActor
private final class AuthorityRequesterStub: AccountAuthorityRequesting, @unchecked Sendable {
    struct ChallengeRequest: Equatable {
        let purpose: AuthorityPurpose
        let stepUp: AuthorityStepUp
    }

    struct Submission: Equatable {
        let record: String
        let signature: String
        let challenge: String
        let recoveryArtifactConfirmed: Bool
    }

    struct ApprovalSignature: Equatable {
        let approvalID: String
        let signature: String
    }

    var challenge = GuaBase64URL.encode([UInt8](repeating: 0x33, count: 32))
    var stateToReturn: AuthorityChainState?
    var approvalsToReturn: [AuthorityApproval] = []
    var submissionError: Error?

    private(set) var challengeRequests: [ChallengeRequest] = []
    private(set) var adoptions: [Submission] = []
    private(set) var grants: [Submission] = []
    private(set) var approvalSignatures: [ApprovalSignature] = []
    private(set) var callCount = 0

    func authorityChallenge(accessToken: String, purpose: AuthorityPurpose, stepUp: AuthorityStepUp) async throws -> AuthorityChallenge {
        callCount += 1
        challengeRequests.append(ChallengeRequest(purpose: purpose, stepUp: stepUp))
        return AuthorityChallenge(challenge: challenge, expiresAt: Date().addingTimeInterval(900))
    }

    func submitAuthorityAdoption(accessToken: String,
                                 record: String,
                                 signature: String,
                                 challenge: String,
                                 recoveryArtifactConfirmed: Bool) async throws -> AuthoritySubmission {
        callCount += 1
        adoptions.append(Submission(record: record,
                                    signature: signature,
                                    challenge: challenge,
                                    recoveryArtifactConfirmed: recoveryArtifactConfirmed))
        if let submissionError { throw submissionError }
        return AuthoritySubmission(seq: 1, isPending: true, effectiveAt: Date().addingTimeInterval(259_200), recordHash: "hash")
    }

    func submitAuthorityDeviceGrant(accessToken: String,
                                    record: String,
                                    signature: String,
                                    challenge: String) async throws -> AuthoritySubmission {
        callCount += 1
        grants.append(Submission(record: record, signature: signature, challenge: challenge, recoveryArtifactConfirmed: false))
        if let submissionError { throw submissionError }
        return AuthoritySubmission(seq: 5, isPending: false, effectiveAt: Date(), recordHash: "hash")
    }

    func authorityState(accessToken: String) async throws -> AuthorityChainState {
        callCount += 1
        guard let stateToReturn else { throw IdentityServiceError.authority(.noAccount) }
        return stateToReturn
    }

    func liveAuthorityApprovals(accessToken: String) async throws -> [AuthorityApproval] {
        callCount += 1
        return approvalsToReturn
    }

    func signAuthorityApproval(accessToken: String, approvalID: String, signature: String) async throws {
        callCount += 1
        approvalSignatures.append(ApprovalSignature(approvalID: approvalID, signature: signature))
        if let submissionError { throw submissionError }
    }
}

@MainActor
private final class AuthorityKeyStoreStub: AccountAuthorityKeyStoreProtocol {
    var stored: [String: AccountAuthorityKeyPair] = [:]
    var refusesToPersist = false

    func generateKeyPair() -> AccountAuthorityKeyPair {
        AccountAuthorityKeyPair(authority: Curve25519.Signing.PrivateKey(),
                                recovery: Curve25519.Signing.PrivateKey())
    }

    func persist(_ keyPair: AccountAuthorityKeyPair, forAccountID accountID: String) throws {
        if refusesToPersist { throw AccountAuthorityKeyStoreError.keychain("refused") }
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
