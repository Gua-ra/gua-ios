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
    private var installationIDStore: AuthorityInstallationIDStoreStub!
    private var pushTokenStore: AuthorityPushTokenStore!
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
        installationIDStore = AuthorityInstallationIDStoreStub()
        pushTokenStore = AuthorityPushTokenStore(token: "0011aabb")
        service = AccountAuthorityService(client: client,
                                          keyStore: keyStore,
                                          installationIDStore: installationIDStore,
                                          pushTokenStore: pushTokenStore,
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
        // Every surface the lifecycle added, not only the two that existed before it: a deployment with the
        // flag down has to behave exactly as it did, and one method that forgot the gate is the whole
        // difference between that and a feature that is half on.
        await assertThrowsDisabled {
            try await self.service.offerThisDevice(accessToken: "token",
                                                   state: self.chainState(headSeq: 1, headHash: String(repeating: "0", count: 64)))
        }
        await assertThrowsDisabled { try await self.service.candidates(accessToken: "token") }
        await assertThrowsDisabled {
            try await self.service.prepareRecovery(accessToken: "token",
                                                   state: self.chainState(headSeq: 1, headHash: String(repeating: "0", count: 64)),
                                                   typedArtifact: "",
                                                   stepUp: .pin("123456"))
        }
        await assertThrowsDisabled {
            try await self.service.prepareRecoveryThroughAccountRecovery(accessToken: "token",
                                                                         state: self.chainState(headSeq: 1, headHash: String(repeating: "0", count: 64)),
                                                                         stepUp: .pin("123456"))
        }
        await assertThrowsDisabled {
            try await self.service.revokeDevice(accessToken: "token",
                                                state: self.chainState(headSeq: 1, headHash: String(repeating: "0", count: 64)),
                                                deviceKey: GuaBase64URL.encode([UInt8](repeating: 0x11, count: 32)),
                                                reason: AuthorityRecord.reasonUnspecified,
                                                stepUp: .pin("123456"))
        }
        await assertThrowsDisabled {
            try await self.service.registerSecurityAlerts(accessToken: "token", accountID: self.accountID)
        }
        await assertThrowsDisabled { try await self.service.securityAlerts(accessToken: "token") }
        await assertThrowsDisabledVoid {
            try await self.service.oppose(accessToken: "token",
                                          state: self.chainState(headSeq: 1, headHash: String(repeating: "0", count: 64)),
                                          pending: Self.pending(type: .deviceRevoke),
                                          stepUp: nil)
        }
        await assertThrowsDisabledVoid {
            try await self.service.removeSecurityAlerts(accessToken: "token",
                                                        accountID: self.accountID,
                                                        installationID: "install",
                                                        stepUp: .pin("123456"))
        }
        await assertThrowsDisabled {
            try await self.service.webStepUpURL(accessToken: "token", purpose: .adopt)
        }

        XCTAssertEqual(client.callCount, 0, "No request may be made while the flag is off.")
        XCTAssertTrue(keyStore.stored.isEmpty, "No key may be created or stored while the flag is off.")
        XCTAssertNil(service.thisInstallationID(), "No installation id is minted while the flag is off.")
        XCTAssertEqual(installationIDStore.reads, 0)
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
        // Read back through the decoder a person's retyped copy goes through, so the artifact on screen and
        // the key the record commits are checked against each other in the shape the other phone accepts.
        XCTAssertEqual(try AuthorityRecoveryArtifact.parse(artifact).rawRepresentation,
                       stored.recovery.rawRepresentation)

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
            _ = try await service.submit(accessToken: "token", prepared: prepared)
            XCTFail("An unconfirmed adoption must not be submitted.")
        } catch {
            XCTAssertEqual(error as? AccountAuthorityServiceError, .artifactUnconfirmed)
        }
        XCTAssertEqual(client.adoptions.count, 0, "The request must never be made, not merely refused by the server.")

        prepared.confirmArtifactStored()
        _ = try await service.submit(accessToken: "token", prepared: prepared)

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
        _ = try? await service.submit(accessToken: "token", prepared: refused)
        XCTAssertNil(keyStore.stored[accountID.value],
                     "A refusal the server made up its mind about leaves keys no record will ever name.")

        let lost = try await service.prepareAdoption(accessToken: "token", accountID: accountID, stepUp: .pin("123456"))
        lost.confirmArtifactStored()
        client.submissionError = IdentityServiceError.transport(URLError(.timedOut))
        _ = try? await service.submit(accessToken: "token", prepared: lost)
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
                                              candidate: Self.candidate(for: granteeKey, label: "iPad"),
                                              comparisonConfirmed: true,
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
                                                  candidate: Self.candidate(for: [UInt8](Curve25519.Signing.PrivateKey().publicKey.rawRepresentation),
                                                                            label: "iPad"),
                                                  comparisonConfirmed: true,
                                                  stepUp: .pin("123456"))
            XCTFail("A device with no key in the chain has nothing to sign with.")
        } catch {
            XCTAssertEqual(error as? AccountAuthorityServiceError, .notAnAuthorityDevice)
        }
        XCTAssertEqual(client.challengeRequests.count, 0, "Nothing is spent before the key is known to be here.")
    }

    // MARK: - The candidate step

    func testOfferingThisDeviceSendsOnlyThePublicHalfAndShowsAFingerprintItComputedItself() async throws {
        appSettings.guaAccountAuthorityEnabled = true
        // The server's own fingerprint is deliberately wrong here. What the screen shows has to be the one
        // this phone derived from the key, because a server-issued string would make the comparison across
        // the room mean "both spoke to the same server", which is already assumed.
        client.fingerprintToReturn = "ZZZZZZZZ"

        let offer = try await service.offerThisDevice(accessToken: "token",
                                                      state: chainState(headSeq: 1, headHash: String(repeating: "0", count: 64)))

        let offered = try XCTUnwrap(client.offeredCandidates.first)
        let key = try XCTUnwrap(GuaBase64URL.decode(offered))
        XCTAssertEqual(key.count, 32, "Only the 32 public bytes leave this device.")
        XCTAssertEqual(key, try [UInt8](keyStore.authorityKey(forAccountID: accountID.value).publicKey.rawRepresentation))
        XCTAssertEqual(offer.fingerprint, AuthorityFingerprint.of(key))
        XCTAssertNotEqual(offer.fingerprint, "ZZZZZZZZ")
        XCTAssertEqual(client.challengeRequests.count, 0, "Offering a public key grants nothing, so it spends no factor.")
    }

    func testOfferingThisDeviceTwiceOffersTheSameKey() async throws {
        appSettings.guaAccountAuthorityEnabled = true

        let empty = chainState(headSeq: 1, headHash: String(repeating: "0", count: 64))
        let first = try await service.offerThisDevice(accessToken: "token", state: empty)
        let second = try await service.offerThisDevice(accessToken: "token", state: empty)

        // A second key pair would leave the phone with two answers to "which key is mine" and would orphan
        // whichever the chain ends up naming.
        XCTAssertEqual(first.deviceKeyB64, second.deviceKeyB64)
    }

    func testAKeyTheChainAlreadyNamesIsNotOfferedBackButReplaced() async throws {
        appSettings.guaAccountAuthorityEnabled = true
        let revoked = Curve25519.Signing.PrivateKey()
        keyStore.stored[accountID.value] = AccountAuthorityKeyPair(authority: revoked,
                                                                   recovery: Curve25519.Signing.PrivateKey())
        let revokedKeyB64 = GuaBase64URL.encode([UInt8](revoked.publicKey.rawRepresentation))
        let state = AuthorityChainState(accountID: accountID,
                                        accountClass: .bootstrap,
                                        state: .rooted,
                                        headSeq: 3,
                                        headHash: String(repeating: "ab", count: 32),
                                        devices: [AuthorityDeviceSummary(deviceKey: revokedKeyB64,
                                                                         label: "This phone",
                                                                         state: .revoked,
                                                                         quarantineUntil: nil,
                                                                         grantedSeq: 2)],
                                        pending: nil)

        let offer = try await service.offerThisDevice(accessToken: "token", state: state)

        // Offering a revoked key back is a revocation with no effect, and the chain cannot say whether the
        // device was removed because it was lost or because it was in someone else's hands. A fresh pair
        // leaves that question to the owner instead of answering it for them.
        XCTAssertNotEqual(offer.deviceKeyB64, revokedKeyB64)
        XCTAssertEqual(offer.deviceKeyB64,
                       try GuaBase64URL.encode([UInt8](keyStore.authorityKey(forAccountID: accountID.value).publicKey.rawRepresentation)))
    }

    func testAGrantIsRefusedWhenTheComparisonWasNotMadeOrTheFingerprintDisagrees() async throws {
        appSettings.guaAccountAuthorityEnabled = true
        keyStore.stored[accountID.value] = AccountAuthorityKeyPair(authority: Curve25519.Signing.PrivateKey(),
                                                                   recovery: Curve25519.Signing.PrivateKey())
        let granteeKey = [UInt8](Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        let state = chainState(headSeq: 4, headHash: String(repeating: "ab", count: 32))

        do {
            _ = try await service.signDeviceGrant(accessToken: "token",
                                                  state: state,
                                                  candidate: Self.candidate(for: granteeKey, label: "iPad"),
                                                  comparisonConfirmed: false,
                                                  stepUp: .pin("123456"))
            XCTFail("A grant with no comparison is a grant over whatever came up the wire.")
        } catch {
            XCTAssertEqual(error as? AccountAuthorityServiceError, .candidateUnverified)
        }

        // A candidate whose fingerprint does not belong to its key is the substitution the comparison
        // exists to catch, so it is refused even with the confirmation on.
        let mismatched = AuthorityCandidate(deviceKeyB64: GuaBase64URL.encode(granteeKey),
                                            fingerprint: "ABCD2346",
                                            label: "iPad",
                                            expiresAt: Date().addingTimeInterval(600))
        do {
            _ = try await service.signDeviceGrant(accessToken: "token",
                                                  state: state,
                                                  candidate: mismatched,
                                                  comparisonConfirmed: true,
                                                  stepUp: .pin("123456"))
            XCTFail("A fingerprint that does not belong to the key must not be signed over.")
        } catch {
            XCTAssertEqual(error as? AccountAuthorityServiceError, .candidateUnverified)
        }

        XCTAssertEqual(client.challengeRequests.count, 0, "Nothing is spent before the comparison holds.")
        XCTAssertTrue(client.grants.isEmpty)
    }

    // MARK: - Revocation

    func testARevocationNamesTheRemovedKeyAndIsSignedByThisDevice() async throws {
        appSettings.guaAccountAuthorityEnabled = true
        let deviceKey = Curve25519.Signing.PrivateKey()
        keyStore.stored[accountID.value] = AccountAuthorityKeyPair(authority: deviceKey,
                                                                   recovery: Curve25519.Signing.PrivateKey())
        let removed = [UInt8](Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        let headHash = String(repeating: "ab", count: 32)

        _ = try await service.revokeDevice(accessToken: "token",
                                           state: chainState(headSeq: 5, headHash: headHash),
                                           deviceKey: GuaBase64URL.encode(removed),
                                           reason: AuthorityRecord.reasonCompromised,
                                           stepUp: .pin("123456"))

        let submitted = try XCTUnwrap(client.revocations.first)
        let bytes = try XCTUnwrap(GuaBase64URL.decode(submitted.record))
        XCTAssertEqual(Array(bytes[0..<4]), Array("GUAX".utf8))
        XCTAssertEqual(Array(bytes[80..<112]), removed)
        XCTAssertEqual(bytes[112], AuthorityRecord.reasonCompromised)
        // The signer is the key that authorizes it, never the key it removes: the device named in a
        // revocation may not veto its own removal, so it cannot be its signer either.
        XCTAssertEqual(Array(bytes[113..<145]), [UInt8](deviceKey.publicKey.rawRepresentation))
        XCTAssertEqual(client.challengeRequests.first?.purpose, .revoke)
        XCTAssertNotNil(try? keyStore.authorityKey(forAccountID: accountID.value),
                        "Revoking another device leaves this one's key where it is.")
    }

    func testAnImmediateSelfRevocationDropsThisDevicesOwnKey() async throws {
        appSettings.guaAccountAuthorityEnabled = true
        let deviceKey = Curve25519.Signing.PrivateKey()
        keyStore.stored[accountID.value] = AccountAuthorityKeyPair(authority: deviceKey,
                                                                   recovery: Curve25519.Signing.PrivateKey())
        client.revocationIsPending = false

        _ = try await service.revokeDevice(accessToken: "token",
                                           state: chainState(headSeq: 5, headHash: String(repeating: "ab", count: 32)),
                                           deviceKey: GuaBase64URL.encode([UInt8](deviceKey.publicKey.rawRepresentation)),
                                           reason: AuthorityRecord.reasonReplaced,
                                           stepUp: .pin("123456"))

        // "Stop trusting this phone" has to be true on the phone as well as on the chain.
        XCTAssertNil(try? keyStore.authorityKey(forAccountID: accountID.value))
    }

    func testAPendingSelfRevocationKeepsTheKeyBecauseItCanStillBeOpposed() async throws {
        appSettings.guaAccountAuthorityEnabled = true
        let deviceKey = Curve25519.Signing.PrivateKey()
        keyStore.stored[accountID.value] = AccountAuthorityKeyPair(authority: deviceKey,
                                                                   recovery: Curve25519.Signing.PrivateKey())
        client.revocationIsPending = true

        _ = try await service.revokeDevice(accessToken: "token",
                                           state: chainState(headSeq: 5, headHash: String(repeating: "ab", count: 32)),
                                           deviceKey: GuaBase64URL.encode([UInt8](deviceKey.publicKey.rawRepresentation)),
                                           reason: AuthorityRecord.reasonReplaced,
                                           stepUp: .pin("123456"))

        XCTAssertNotNil(try? keyStore.authorityKey(forAccountID: accountID.value))
    }

    // MARK: - Opposition

    func testOpposingAnAdoptionGoesThroughTheSessionAndPresentsNoFactor() async throws {
        appSettings.guaAccountAuthorityEnabled = true
        let pending = Self.pending(type: .adoptRoot)

        try await service.oppose(accessToken: "token",
                                 state: chainState(headSeq: 1, headHash: String(repeating: "0", count: 64)),
                                 pending: pending,
                                 stepUp: nil)

        XCTAssertEqual(client.sessionOppositions, [pending.recordHash])
        XCTAssertTrue(client.signedOppositions.isEmpty)
        XCTAssertEqual(client.challengeRequests.count, 0,
                       "At seq 1 the account holds no authority to weigh, so no challenge and no factor.")
    }

    func testOpposingARevocationIsASignedRecordThatTakesTheSlotItCancels() async throws {
        appSettings.guaAccountAuthorityEnabled = true
        let deviceKey = Curve25519.Signing.PrivateKey()
        keyStore.stored[accountID.value] = AccountAuthorityKeyPair(authority: deviceKey,
                                                                   recovery: Curve25519.Signing.PrivateKey())
        let headHash = String(repeating: "ab", count: 32)
        let pending = Self.pending(type: .deviceRevoke)

        try await service.oppose(accessToken: "token",
                                 state: chainState(headSeq: 2, headHash: headHash),
                                 pending: pending,
                                 stepUp: nil)

        XCTAssertTrue(client.sessionOppositions.isEmpty, "A session's word is refused for anything but an adoption.")
        let submitted = try XCTUnwrap(client.signedOppositions.first)
        let bytes = try XCTUnwrap(GuaBase64URL.decode(submitted.record))
        XCTAssertEqual(Array(bytes[0..<4]), Array("GUAO".utf8))
        // It takes no slot and is never appended, so it carries the seq and prevHash of the record it
        // cancels rather than the position after it.
        XCTAssertEqual(Array(bytes[40..<72]), AuthorityRecord.hashBytes(fromHex: headHash))
        XCTAssertEqual(Array(bytes[72..<80]), [0, 0, 0, 0, 0, 0, 0, 3])
        XCTAssertEqual(Array(bytes[80..<112]), AuthorityRecord.hashBytes(fromHex: pending.recordHash))
        XCTAssertEqual(Array(bytes[112..<144]), [UInt8](deviceKey.publicKey.rawRepresentation))
        // No factor is asked for and no hold is weighed: the holds gate starting a transition and never
        // opposing one, so an owner who has just changed their PIN is not the one disarmed by it.
        XCTAssertEqual(client.challengeRequests.first?.purpose, .oppose)
        XCTAssertNil(client.challengeRequests.first?.stepUp)
    }

    // MARK: - Recovery with the artifact

    func testTheArtifactRoundTripsAndMalformedMaterialIsRefusedBeforeAnythingIsSpent() async throws {
        appSettings.guaAccountAuthorityEnabled = true
        let key = Curve25519.Signing.PrivateKey()
        let rendered = AuthorityRecoveryArtifact.render(key)

        // The framework and its version, first, exactly as the other platform renders and requires it: an
        // artifact taken on one phone is typed into whichever phone replaces it.
        XCTAssertTrue(rendered.hasPrefix(AuthorityRecoveryArtifact.prefix + " "), rendered)

        // Read off one screen and typed into another: the grouping and the case are forgiven, because the
        // encoding has neither.
        let parsed = try AuthorityRecoveryArtifact.parse(rendered.uppercased())
        XCTAssertEqual(parsed.rawRepresentation, key.rawRepresentation)
        let body = rendered.dropFirst(AuthorityRecoveryArtifact.prefix.count).filter { !$0.isWhitespace }
        XCTAssertEqual(try AuthorityRecoveryArtifact.parse("\(AuthorityRecoveryArtifact.prefix) \(body)").rawRepresentation,
                       key.rawRepresentation)
        XCTAssertEqual(try AuthorityRecoveryArtifact.parse("  \(rendered)\n").rawRepresentation,
                       key.rawRepresentation)

        // The bare body is the shape this client used to render, and it is refused now rather than being
        // half-accepted: a key with no framework on it is not this framework's key.
        for wrong in ["", "not a key", String(body), AuthorityRecoveryArtifact.prefix,
                      "gua-recovery-2 \(body)", String(repeating: "a", count: 51), rendered + "a"] {
            XCTAssertThrowsError(try AuthorityRecoveryArtifact.parse(wrong)) { error in
                XCTAssertEqual(error as? AccountAuthorityServiceError, .artifactMalformed)
            }
        }

        do {
            _ = try await service.prepareRecovery(accessToken: "token",
                                                  state: chainState(headSeq: 1, headHash: String(repeating: "0", count: 64)),
                                                  typedArtifact: "not a key",
                                                  stepUp: .pin("123456"))
            XCTFail("Malformed material must be refused before a challenge is minted.")
        } catch {
            XCTAssertEqual(error as? AccountAuthorityServiceError, .artifactMalformed)
        }
        XCTAssertEqual(client.challengeRequests.count, 0)
        XCTAssertTrue(client.recoveries.isEmpty)
    }

    func testARecoveryUnderTheTypedKeyIsSignedByItAndInstallsTwoFreshKeys() async throws {
        appSettings.guaAccountAuthorityEnabled = true
        let committedRecoveryKey = Curve25519.Signing.PrivateKey()
        let headHash = String(repeating: "ab", count: 32)

        let prepared = try await service.prepareRecovery(accessToken: "token",
                                                         state: chainState(headSeq: 1, headHash: headHash),
                                                         typedArtifact: AuthorityRecoveryArtifact.render(committedRecoveryKey),
                                                         stepUp: .pin("123456"))
        XCTAssertEqual(prepared.kind, .recoveryUnderRecoveryKey)
        // A new recovery key is minted, so the same rule as adoption applies: it is shown once and the
        // record is refused until the user says they stored it.
        XCTAssertNotNil(prepared.recoveryArtifact)
        prepared.confirmArtifactStored()
        _ = try await service.submit(accessToken: "token", prepared: prepared)

        let submitted = try XCTUnwrap(client.recoveries.first)
        let bytes = try XCTUnwrap(GuaBase64URL.decode(submitted.record))
        XCTAssertEqual(Array(bytes[0..<4]), Array("GUAR".utf8))
        XCTAssertEqual(Array(bytes[40..<72]), AuthorityRecord.hashBytes(fromHex: headHash))
        XCTAssertEqual(bytes[176], AuthorityRecord.authorizationRecoveryKey)
        XCTAssertEqual(Array(bytes[177..<209]), [UInt8](committedRecoveryKey.publicKey.rawRepresentation))

        let stored = try keyStore.authorityKey(forAccountID: accountID.value)
        XCTAssertEqual(Array(bytes[80..<112]), [UInt8](stored.publicKey.rawRepresentation),
                       "The device key in the record is the one this phone kept.")
        XCTAssertNotEqual(Array(bytes[112..<144]), [UInt8](committedRecoveryKey.publicKey.rawRepresentation),
                          "A recovery that reinstalled the same recovery key would not recover from it being known.")
        XCTAssertEqual(client.challengeRequests.first?.purpose, .recover)

        let challenge = try XCTUnwrap(GuaBase64URL.decode(submitted.challenge))
        let preimage = try AuthorityProofs.recordPreimage(type: .authorityRecovery,
                                                          challenge: challenge,
                                                          canonicalBytes: bytes)
        let signature = try XCTUnwrap(GuaBase64URL.decode(submitted.signature))
        XCTAssertTrue(committedRecoveryKey.publicKey.isValidSignature(Data(signature), for: Data(preimage)),
                      "Rank 2 is signed by the key the account committed for exactly this.")
    }

    func testTheAccountRecoveryPathNamesNoKeyAndIsSignedByTheDeviceItInstalls() async throws {
        appSettings.guaAccountAuthorityEnabled = true

        let prepared = try await service
            .prepareRecoveryThroughAccountRecovery(accessToken: "token",
                                                   state: chainState(headSeq: 1, headHash: String(repeating: "ab", count: 32)),
                                                   stepUp: .pin("123456"))
        XCTAssertEqual(prepared.kind, .recoveryThroughAccountRecovery)
        prepared.confirmArtifactStored()
        _ = try await service.submit(accessToken: "token", prepared: prepared)

        let submitted = try XCTUnwrap(client.recoveries.first)
        let bytes = try XCTUnwrap(GuaBase64URL.decode(submitted.record))
        XCTAssertEqual(bytes[176], AuthorityRecord.authorizationAccountRecovery)
        XCTAssertEqual(Array(bytes[177..<209]), AuthorityRecord.zeroKey,
                       "Under the weaker path the field is all zero by rule, whatever the caller passed.")

        let stored = try keyStore.authorityKey(forAccountID: accountID.value)
        let challenge = try XCTUnwrap(GuaBase64URL.decode(submitted.challenge))
        let preimage = try AuthorityProofs.recordPreimage(type: .authorityRecovery,
                                                          challenge: challenge,
                                                          canonicalBytes: bytes)
        let signature = try XCTUnwrap(GuaBase64URL.decode(submitted.signature))
        XCTAssertTrue(stored.publicKey.isValidSignature(Data(signature), for: Data(preimage)),
                      "Here the account has no other key left, so the signer is the device being installed.")
    }

    // MARK: - The security notification channel

    func testARegistrationCarriesTheInstallationIDTheTokenAndASignedBindingToThisDevicesKey() async throws {
        appSettings.guaAccountAuthorityEnabled = true
        let deviceKey = Curve25519.Signing.PrivateKey()
        keyStore.stored[accountID.value] = AccountAuthorityKeyPair(authority: deviceKey,
                                                                   recovery: Curve25519.Signing.PrivateKey())

        _ = try await service.registerSecurityAlerts(accessToken: "token", accountID: accountID)

        let registration = try XCTUnwrap(client.registrations.first)
        XCTAssertEqual(registration.installationID, installationIDStore.value)
        XCTAssertEqual(registration.token, "0011aabb")
        XCTAssertEqual(registration.platform, "APNS")
        XCTAssertEqual(registration.authorityDeviceKeyB64,
                       GuaBase64URL.encode([UInt8](deviceKey.publicKey.rawRepresentation)))
        XCTAssertEqual(client.challengeRequests.first?.purpose, .notify)
        XCTAssertNil(client.challengeRequests.first?.stepUp, "Binding a registration asks for no factor.")

        // The key on the row is proved rather than claimed. Without the signature an attacker could name
        // the owner's key on their own row, or plant a row the owner's own device can never remove.
        let challenge = try XCTUnwrap(try GuaBase64URL.decode(XCTUnwrap(registration.challenge)))
        let preimage = try AuthorityProofs.notificationPreimage(accountID: accountID,
                                                                installationID: installationIDStore.value,
                                                                deviceKey: [UInt8](deviceKey.publicKey.rawRepresentation),
                                                                challenge: challenge)
        let signature = try XCTUnwrap(try GuaBase64URL.decode(XCTUnwrap(registration.signature)))
        XCTAssertTrue(deviceKey.publicKey.isValidSignature(Data(signature), for: Data(preimage)))
    }

    func testAnInstallWithNoDeviceKeyRegistersWithoutABindingAndNotWithAnUnprovenOne() async throws {
        appSettings.guaAccountAuthorityEnabled = true

        _ = try await service.registerSecurityAlerts(accessToken: "token", accountID: accountID)

        let registration = try XCTUnwrap(client.registrations.first)
        XCTAssertNil(registration.authorityDeviceKeyB64)
        XCTAssertNil(registration.signature)
        XCTAssertEqual(client.challengeRequests.count, 0)
    }

    func testWithNoPushDestinationNothingIsRegistered() async throws {
        appSettings.guaAccountAuthorityEnabled = true
        service = AccountAuthorityService(client: client,
                                          keyStore: keyStore,
                                          installationIDStore: installationIDStore,
                                          pushTokenStore: AuthorityPushTokenStore(),
                                          appSettings: appSettings,
                                          deviceLabel: "iPhone")

        do {
            _ = try await service.registerSecurityAlerts(accessToken: "token", accountID: accountID)
            XCTFail("There is nothing to register a channel to.")
        } catch {
            XCTAssertEqual(error as? AccountAuthorityServiceError, .noPushToken)
        }
        XCTAssertTrue(client.registrations.isEmpty)
    }

    /// One tier, whichever row is named (ADM-009 decision 13). The own row pays the same price as any
    /// other, and the request carries no field for the caller to name itself with, because that field was
    /// what selected the cheaper tier the server has removed.
    func testEveryRemovalCarriesTheFactorAndSignsTheRowItNames() async throws {
        appSettings.guaAccountAuthorityEnabled = true
        let deviceKey = Curve25519.Signing.PrivateKey()
        keyStore.stored[accountID.value] = AccountAuthorityKeyPair(authority: deviceKey,
                                                                   recovery: Curve25519.Signing.PrivateKey())

        for installationID in [installationIDStore.value, "another-install"] {
            try await service.removeSecurityAlerts(accessToken: "token",
                                                   accountID: accountID,
                                                   installationID: installationID,
                                                   stepUp: .pin("123456"))
            let removal = try XCTUnwrap(client.removals.last)
            XCTAssertEqual(removal.installationID, installationID)
            XCTAssertEqual(removal.stepUp, .pin("123456"))
            let challenge = try XCTUnwrap(try GuaBase64URL.decode(XCTUnwrap(removal.challenge)))
            let preimage = try AuthorityProofs.notificationPreimage(accountID: accountID,
                                                                    installationID: installationID,
                                                                    deviceKey: [UInt8](deviceKey.publicKey.rawRepresentation),
                                                                    challenge: challenge)
            let signature = try XCTUnwrap(try GuaBase64URL.decode(XCTUnwrap(removal.signature)))
            XCTAssertTrue(deviceKey.publicKey.isValidSignature(Data(signature), for: Data(preimage)),
                          "The preimage names the row being removed, so one row's signature cannot remove another.")
        }
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

    // MARK: - The web step-up

    /// The fallback for a device that cannot run the assertion natively: the same handoff factor
    /// enrollment uses, scoped to one transition and pointed back at this build's own scheme.
    func testTheWebStepUpIsScopedToThePurposeAndReturnsToThisBuild() async throws {
        appSettings.guaAccountAuthorityEnabled = true
        let minted = try XCTUnwrap(URL(string: "https://auth.example/login/enroll/step-up"))
        client.stepUpURLToReturn = minted

        let url = try await service.webStepUpURL(accessToken: "token", purpose: .recover)

        XCTAssertEqual(url, minted)
        XCTAssertEqual(client.stepUpRequests,
                       [.init(purpose: .recover, redirectURI: appSettings.oidcRedirectURL.absoluteString)])
    }

    /// The four purposes that ask for a factor, and no others. A purpose that asks for none would open a
    /// page with nothing to ask and record a proof of nothing, so no request is spent finding that out.
    func testOnlyATransitionThatAsksForAFactorCanOpenASheet() async throws {
        appSettings.guaAccountAuthorityEnabled = true

        for purpose in [AuthorityPurpose.adopt, .grant, .revoke, .recover] {
            _ = try await service.webStepUpURL(accessToken: "token", purpose: purpose)
        }
        XCTAssertEqual(client.stepUpRequests.map(\.purpose), [.adopt, .grant, .revoke, .recover])

        for purpose in [AuthorityPurpose.approve, .oppose, .notify] {
            do {
                _ = try await service.webStepUpURL(accessToken: "token", purpose: purpose)
                XCTFail("\(purpose) must not open a step-up sheet.")
            } catch IdentityServiceError.authority(.stepUpSheetPurposeRefused) {
                // The server's own refusal, in the server's own words.
            }
        }
        XCTAssertEqual(client.stepUpRequests.count, 4, "A refused purpose costs no request.")
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

    private static func candidate(for key: [UInt8], label: String) -> AuthorityCandidate {
        AuthorityCandidate(deviceKeyB64: GuaBase64URL.encode(key),
                           fingerprint: AuthorityFingerprint.of(key) ?? "",
                           label: label,
                           expiresAt: Date().addingTimeInterval(600))
    }

    private static func pending(type: AuthorityPendingType) -> AuthorityPendingTransition {
        AuthorityPendingTransition(type: type,
                                   seq: 3,
                                   effectiveAt: Date().addingTimeInterval(259_200),
                                   recordHash: String(repeating: "cd", count: 32))
    }

    private func assertThrowsDisabledVoid(_ work: () async throws -> Void,
                                          file: StaticString = #filePath,
                                          line: UInt = #line) async {
        do {
            try await work()
            XCTFail("Expected the service to refuse while the flag is off.", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AccountAuthorityServiceError, .disabled, file: file, line: line)
        }
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
        let stepUp: AuthorityStepUp?
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

    struct StepUpRequest: Equatable {
        let purpose: AuthorityPurpose
        let redirectURI: String?
    }

    var stepUpURLToReturn = URL(fileURLWithPath: "/step-up")
    var candidatesToReturn: [AuthorityCandidate] = []
    var notificationsToReturn: [SecurityNotificationSummary] = []
    var fingerprintToReturn: String?
    var revocationIsPending = true

    private(set) var challengeRequests: [ChallengeRequest] = []
    private(set) var stepUpRequests: [StepUpRequest] = []
    private(set) var adoptions: [Submission] = []
    private(set) var grants: [Submission] = []
    private(set) var revocations: [Submission] = []
    private(set) var recoveries: [Submission] = []
    private(set) var sessionOppositions: [String?] = []
    private(set) var signedOppositions: [Submission] = []
    private(set) var offeredCandidates: [String] = []
    private(set) var registrations: [SecurityNotificationRegistration] = []
    private(set) var removals: [SecurityNotificationRemoval] = []
    private(set) var approvalSignatures: [ApprovalSignature] = []
    private(set) var callCount = 0

    func authorityChallenge(accessToken: String, purpose: AuthorityPurpose, stepUp: AuthorityStepUp?) async throws -> AuthorityChallenge {
        callCount += 1
        challengeRequests.append(ChallengeRequest(purpose: purpose, stepUp: stepUp))
        return AuthorityChallenge(challenge: challenge, expiresAt: Date().addingTimeInterval(900))
    }

    func startAuthorityWebStepUp(accessToken: String,
                                 purpose: AuthorityPurpose,
                                 redirectURI: String?) async throws -> URL {
        callCount += 1
        stepUpRequests.append(StepUpRequest(purpose: purpose, redirectURI: redirectURI))
        return stepUpURLToReturn
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

    func submitAuthorityDeviceRevoke(accessToken: String,
                                     record: String,
                                     signature: String,
                                     challenge: String) async throws -> AuthoritySubmission {
        callCount += 1
        revocations.append(Submission(record: record, signature: signature, challenge: challenge, recoveryArtifactConfirmed: false))
        if let submissionError { throw submissionError }
        return AuthoritySubmission(seq: 6, isPending: revocationIsPending, effectiveAt: Date(), recordHash: "hash")
    }

    func submitAuthorityRecovery(accessToken: String,
                                 record: String,
                                 signature: String,
                                 challenge: String) async throws -> AuthoritySubmission {
        callCount += 1
        recoveries.append(Submission(record: record, signature: signature, challenge: challenge, recoveryArtifactConfirmed: false))
        if let submissionError { throw submissionError }
        return AuthoritySubmission(seq: 2, isPending: true, effectiveAt: Date().addingTimeInterval(604_800), recordHash: "hash")
    }

    func opposeAuthorityAdoption(accessToken: String, recordHash: String?, stepUp: AuthorityStepUp?) async throws {
        callCount += 1
        sessionOppositions.append(recordHash)
        if let submissionError { throw submissionError }
    }

    func submitAuthorityOpposition(accessToken: String,
                                   record: String,
                                   signature: String,
                                   challenge: String) async throws {
        callCount += 1
        signedOppositions.append(Submission(record: record, signature: signature, challenge: challenge, recoveryArtifactConfirmed: false))
        if let submissionError { throw submissionError }
    }

    func registerAuthorityCandidate(accessToken: String,
                                    deviceKeyB64: String,
                                    label: String) async throws -> AuthorityCandidate {
        callCount += 1
        offeredCandidates.append(deviceKeyB64)
        return AuthorityCandidate(deviceKeyB64: deviceKeyB64,
                                  fingerprint: fingerprintToReturn ?? (GuaBase64URL.decode(deviceKeyB64).flatMap(AuthorityFingerprint.of) ?? ""),
                                  label: label,
                                  expiresAt: Date().addingTimeInterval(600))
    }

    func authorityCandidates(accessToken: String) async throws -> [AuthorityCandidate] {
        callCount += 1
        return candidatesToReturn
    }

    func registerSecurityNotification(accessToken: String,
                                      registration: SecurityNotificationRegistration) async throws -> SecurityNotificationSummary {
        callCount += 1
        registrations.append(registration)
        return SecurityNotificationSummary(installationID: registration.installationID,
                                           platform: registration.platform,
                                           deviceLabel: registration.deviceLabel ?? "",
                                           tokenFingerprint: "fingerprint",
                                           isBoundToAnAuthorityDevice: registration.authorityDeviceKeyB64 != nil,
                                           lastSeenAt: Date())
    }

    func securityNotifications(accessToken: String) async throws -> [SecurityNotificationSummary] {
        callCount += 1
        return notificationsToReturn
    }

    func removeSecurityNotification(accessToken: String, removal: SecurityNotificationRemoval) async throws {
        callCount += 1
        removals.append(removal)
        if let submissionError { throw submissionError }
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

@MainActor
private final class AuthorityInstallationIDStoreStub: AuthorityInstallationIDStoreProtocol {
    var value = "install-under-test"
    var error: Error?
    private(set) var reads = 0

    func installationID() throws -> String {
        reads += 1
        if let error { throw error }
        return value
    }
}
