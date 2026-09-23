//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Combine
import CryptoKit
@testable import ElementX
import XCTest

@MainActor
final class AccountAuthorityScreenViewModelTests: XCTestCase {
    private var authorityService: AuthorityServiceStub!
    private var viewModel: AccountAuthorityScreenViewModel!

    private var context: AccountAuthorityScreenViewModelType.Context {
        viewModel.context
    }

    private var accountID: AccountID!

    override func setUpWithError() throws {
        accountID = try AccountID.derive(rootClass: AccountID.classBootstrap,
                                         canonicalBytes: [UInt8]("screen-account".utf8))
    }

    private func makeViewModel(chain: AuthorityChainState?,
                               status: AccountSecurityStatus? = nil,
                               passkeyOptions: PasskeyStepUpOptions? = nil,
                               passkeyPresenter: PasskeyStepUpPresenting? = nil) {
        authorityService = AuthorityServiceStub(chain: chain)
        let status = status ?? Self.status(hasPin: true, passkeyRegistered: false)
        let clientProxy = ClientProxyMock(.init())
        clientProxy.accessToken = "access-token"
        viewModel = AccountAuthorityScreenViewModel(authorityService: authorityService,
                                                    identityServiceClient: IdentityServiceClientMock(status: status,
                                                                                                     passkeyStepUpOptions: passkeyOptions),
                                                    clientProxy: clientProxy,
                                                    userIndicatorController: UserIndicatorControllerMock(),
                                                    passkeyStepUpPresenter: passkeyPresenter)
    }

    private func waitForPhase(_ phase: AccountAuthorityScreenPhase) async throws {
        let deferred = deferFulfillment(context.observe(\.viewState.phase)) { $0 == phase }
        try await deferred.fulfill()
    }

    // MARK: - Reading the chain

    func testABootstrapAccountIsOfferedTheSetup() async throws {
        makeViewModel(chain: bootstrapChain())
        try await waitForPhase(.overview)

        XCTAssertTrue(context.viewState.canAdopt)
        XCTAssertEqual(context.viewState.chain?.state, .bootstrap)
    }

    func testAChainThatCannotBeReadIsNotRenderedAsAnEmptyOne() async throws {
        makeViewModel(chain: nil)
        try await waitForPhase(.unavailable)

        XCTAssertNil(context.viewState.chain)
        XCTAssertFalse(context.viewState.canAdopt, "An unreadable chain must never invite a setup.")
    }

    func testQuarantineAndPendingAreReportedAsTheyAre() async throws {
        let quarantineUntil = Date().addingTimeInterval(259_200)
        let chain = AuthorityChainState(accountID: accountID,
                                        accountClass: .bootstrap,
                                        state: .rooted,
                                        headSeq: 2,
                                        headHash: String(repeating: "ab", count: 32),
                                        devices: [device(key: "grantee", state: .quarantined, quarantineUntil: quarantineUntil, grantedSeq: 2),
                                                  device(key: "owner", state: .active, quarantineUntil: nil, grantedSeq: 1)],
                                        pending: AuthorityPendingTransition(type: .deviceRevoke,
                                                                            seq: 3,
                                                                            effectiveAt: quarantineUntil,
                                                                            recordHash: "hash"))
        makeViewModel(chain: chain)
        try await waitForPhase(.overview)

        XCTAssertEqual(context.viewState.pending?.seq, 3)
        XCTAssertEqual(context.viewState.devices.map(\.state), [.active, .quarantined],
                       "This device first, then the rest in the order the chain granted them.")
        XCTAssertEqual(context.viewState.chain?.unquarantinedActiveDevices.count, 1,
                       "A quarantined device does not count toward the account's authority.")
        XCTAssertFalse(context.viewState.canAdopt, "A rooted account is not offered adoption.")
    }

    func testThisDeviceIsNamedWhenTheChainHoldsItsKey() async throws {
        makeViewModel(chain: AuthorityChainState(accountID: accountID,
                                                 accountClass: .bootstrap,
                                                 state: .rooted,
                                                 headSeq: 1,
                                                 headHash: String(repeating: "ab", count: 32),
                                                 devices: [device(key: "other", state: .active, quarantineUntil: nil, grantedSeq: 2),
                                                           device(key: "this-device", state: .active, quarantineUntil: nil, grantedSeq: 1)],
                                                 pending: nil))
        authorityService.deviceKey = "this-device"
        try await waitForPhase(.overview)

        XCTAssertEqual(context.viewState.devices.first?.deviceKey, "this-device")
        XCTAssertTrue(try context.viewState.isThisDevice(XCTUnwrap(context.viewState.devices.first)))
    }

    // MARK: - Adoption

    func testTheAccountPinAuthorizesTheAdoptionWhenThereIsNoPasskey() async throws {
        makeViewModel(chain: bootstrapChain(), status: Self.status(hasPin: true, passkeyRegistered: false))
        try await waitForPhase(.overview)

        context.send(viewAction: .startAdoption)
        try await waitForPhase(.enteringPin)

        context.pin = "123456"
        context.send(viewAction: .pinChanged)
        try await waitForPhase(.artifact)

        XCTAssertEqual(authorityService.preparedStepUps, [.pin("123456")])
        XCTAssertNotNil(context.viewState.recoveryArtifact)
        XCTAssertTrue(context.viewState.bindings.pin.isEmpty, "The PIN is not left on screen behind the artifact.")
    }

    func testAPasskeyHolderIsNeverAskedForAPin() async throws {
        let presenter = PasskeyPresenterStub(result: .success(Self.assertion))
        makeViewModel(chain: bootstrapChain(), status: Self.status(hasPin: true, passkeyRegistered: true),
                      passkeyOptions: Self.passkeyOptions,
                      passkeyPresenter: presenter)
        try await waitForPhase(.overview)

        context.send(viewAction: .startAdoption)
        try await waitForPhase(.artifact)

        XCTAssertEqual(presenter.callCount, 1)
        XCTAssertEqual(authorityService.preparedStepUps, [.passkey(stepUpID: "step-up-id", assertion: Self.assertion)])
    }

    func testAPasskeyThatCannotBeProducedFallsBackToThePin() async throws {
        // Whatever happened inside the ceremony stays on this device: the server is never told a passkey
        // was unavailable, because that claim costs an attacker nothing.
        let presenter = PasskeyPresenterStub(result: .failure(PasskeyStepUpError.cancelled))
        makeViewModel(chain: bootstrapChain(), status: Self.status(hasPin: true, passkeyRegistered: true),
                      passkeyOptions: Self.passkeyOptions,
                      passkeyPresenter: presenter)
        try await waitForPhase(.overview)

        context.send(viewAction: .startAdoption)
        try await waitForPhase(.enteringPin)

        XCTAssertTrue(authorityService.preparedStepUps.isEmpty, "Nothing is spent before a factor is produced.")
    }

    func testAnAccountWithNoFactorIsToldRatherThanOfferedACodeToItsNumber() async throws {
        makeViewModel(chain: bootstrapChain(), status: Self.status(hasPin: false, passkeyRegistered: false))
        try await waitForPhase(.overview)

        context.send(viewAction: .startAdoption)
        let deferred = deferFulfillment(context.observe(\.viewState.errorMessage)) { $0 != nil }
        try await deferred.fulfill()

        XCTAssertEqual(context.viewState.errorMessage, L10n.screenAccountAuthorityErrorStepUp)
        XCTAssertEqual(context.viewState.phase, .overview)
        XCTAssertTrue(authorityService.preparedStepUps.isEmpty)
    }

    func testTwoTapsStartOneAdoption() async throws {
        makeViewModel(chain: bootstrapChain(), status: Self.status(hasPin: true, passkeyRegistered: false))
        try await waitForPhase(.overview)

        context.send(viewAction: .startAdoption)
        context.send(viewAction: .startAdoption)
        try await waitForPhase(.enteringPin)
        context.pin = "123456"
        context.send(viewAction: .pinChanged)
        try await waitForPhase(.artifact)

        // A second pair would overwrite the first in the keychain, leaving the signed record committing a
        // key this device no longer holds.
        XCTAssertEqual(authorityService.preparedStepUps.count, 1)
    }

    // MARK: - The recovery artifact

    func testAdoptionIsUnreachableUntilTheArtifactIsConfirmed() async throws {
        makeViewModel(chain: bootstrapChain())
        try await waitForPhase(.overview)
        context.send(viewAction: .startAdoption)
        try await waitForPhase(.enteringPin)
        context.pin = "123456"
        context.send(viewAction: .pinChanged)
        try await waitForPhase(.artifact)

        XCTAssertFalse(context.viewState.canSubmitArtifact)
        context.send(viewAction: .submitArtifact)
        XCTAssertEqual(authorityService.submissions, 0, "Nothing is submitted while the confirmation is off.")

        context.hasStoredRecoveryArtifact = true
        XCTAssertTrue(context.viewState.canSubmitArtifact)
        context.send(viewAction: .submitArtifact)
        try await waitForPhase(.overview)

        XCTAssertEqual(authorityService.submissions, 1)
        XCTAssertNil(context.viewState.recoveryArtifact, "The key is shown once and not kept on screen after it.")
    }

    func testLeavingTheFlowDropsThePreparedAdoption() async throws {
        makeViewModel(chain: bootstrapChain())
        try await waitForPhase(.overview)
        context.send(viewAction: .startAdoption)
        try await waitForPhase(.enteringPin)
        context.pin = "123456"
        context.send(viewAction: .pinChanged)
        try await waitForPhase(.artifact)

        context.send(viewAction: .cancel)

        XCTAssertEqual(context.viewState.phase, .overview)
        XCTAssertNil(context.viewState.recoveryArtifact)
        XCTAssertFalse(context.viewState.bindings.hasStoredRecoveryArtifact)
        // Its challenge is single use and its keys are unreferenced until a record naming them is on the
        // chain, so an abandoned preparation leaves nothing half-rooted.
        context.send(viewAction: .submitArtifact)
        XCTAssertEqual(authorityService.submissions, 0)
    }

    // MARK: - The passkey-only account

    func testAPasskeyOnlyAccountIsNeverToldToAddAPin() async throws {
        // The ceremony does not complete and the account holds no PIN. The honest answer is that the
        // passkey did not go through; telling this account to set up a PIN would be an instruction to add a
        // weaker factor in order to gain authority, which is exactly what C4 forbids.
        let presenter = PasskeyPresenterStub(result: .failure(PasskeyStepUpError.cancelled))
        makeViewModel(chain: bootstrapChain(),
                      status: Self.status(hasPin: false, passkeyRegistered: true),
                      passkeyOptions: Self.passkeyOptions,
                      passkeyPresenter: presenter)
        try await waitForPhase(.overview)

        context.send(viewAction: .startAdoption)
        let deferred = deferFulfillment(context.observe(\.viewState.errorMessage)) { $0 != nil }
        try await deferred.fulfill()

        XCTAssertEqual(context.viewState.errorMessage, L10n.screenAccountAuthorityErrorPasskeyIncomplete)
        XCTAssertNotEqual(context.viewState.errorMessage, L10n.screenAccountAuthorityErrorStepUp)
        XCTAssertEqual(context.viewState.phase, .overview, "The PIN screen is never reached.")
        XCTAssertTrue(authorityService.preparedStepUps.isEmpty)
    }

    func testAPasskeyOnlyAccountWithNoCeremonyAvailableIsToldTheSameThing() async throws {
        // No presenter at all, which is what a context that cannot run the system sheet looks like.
        makeViewModel(chain: bootstrapChain(),
                      status: Self.status(hasPin: false, passkeyRegistered: true),
                      passkeyOptions: Self.passkeyOptions,
                      passkeyPresenter: nil)
        try await waitForPhase(.overview)

        context.send(viewAction: .startAdoption)
        let deferred = deferFulfillment(context.observe(\.viewState.errorMessage)) { $0 != nil }
        try await deferred.fulfill()

        XCTAssertEqual(context.viewState.errorMessage, L10n.screenAccountAuthorityErrorPasskeyIncomplete)
        XCTAssertEqual(context.viewState.phase, .overview)
    }

    // MARK: - Opposition

    func testAPendingAdoptionCanBeOpposedFromAnySession() async throws {
        makeViewModel(chain: rootedChain(pending: AuthorityPendingTransition(type: .adoptRoot,
                                                                             seq: 1,
                                                                             effectiveAt: Date().addingTimeInterval(259_200),
                                                                             recordHash: "adoption-hash")))
        try await waitForPhase(.overview)

        // No device key on this phone at all, and the button is still offered: at seq 1 the account holds no
        // authority to weigh, so the honest veto is that someone who can read the notifications says no.
        XCTAssertNil(context.viewState.thisDeviceKey)
        XCTAssertTrue(context.viewState.canOpposePending)

        context.send(viewAction: .opposePending)
        try await waitForPhase(.overview)

        XCTAssertEqual(authorityService.oppositions, ["adoption-hash"])
        XCTAssertEqual(authorityService.opposedStepUps, [nil], "The holds gate starting a transition, never opposing one.")
    }

    func testAPendingRevocationIsOnlyOpposableFromADeviceTheChainHoldsActive() async throws {
        let pending = AuthorityPendingTransition(type: .deviceRevoke,
                                                 seq: 3,
                                                 effectiveAt: Date().addingTimeInterval(259_200),
                                                 recordHash: "revocation-hash")
        makeViewModel(chain: rootedChain(pending: pending,
                                         devices: [device(key: "this-device", state: .quarantined,
                                                          quarantineUntil: Date().addingTimeInterval(1000), grantedSeq: 2)]))
        authorityService.deviceKey = "this-device"
        try await waitForPhase(.overview)

        // A quarantined device may not sign one, so the screen does not offer an action the server refuses
        // on the one screen where a refusal costs the owner the window.
        XCTAssertFalse(context.viewState.canOpposePending)

        makeViewModel(chain: rootedChain(pending: pending,
                                         devices: [device(key: "this-device", state: .active, quarantineUntil: nil, grantedSeq: 2)]))
        authorityService.deviceKey = "this-device"
        try await waitForPhase(.overview)

        XCTAssertTrue(context.viewState.canOpposePending)
        context.send(viewAction: .opposePending)
        try await waitForPhase(.overview)
        XCTAssertEqual(authorityService.oppositions, ["revocation-hash"])
    }

    // MARK: - Adding a device

    func testOfferingThisPhoneShowsAFingerprintAndSpendsNoFactor() async throws {
        makeViewModel(chain: rootedChain(pending: nil))
        try await waitForPhase(.overview)

        context.send(viewAction: .offerThisDevice)
        try await waitForPhase(.offeringThisDevice)

        XCTAssertEqual(authorityService.offers, 1)
        XCTAssertEqual(context.viewState.ownOffer?.fingerprint, "ABCD2346")
        XCTAssertTrue(authorityService.preparedStepUps.isEmpty)
    }

    func testAGrantIsUnreachableUntilTheFingerprintsAreSaidToMatch() async throws {
        let candidate = AuthorityCandidate(deviceKeyB64: "offered-key",
                                           fingerprint: "ABCD2346",
                                           label: "iPad",
                                           expiresAt: Date().addingTimeInterval(600))
        makeViewModel(chain: rootedChain(pending: nil,
                                         devices: [device(key: "this-device", state: .active, quarantineUntil: nil, grantedSeq: 1)]))
        authorityService.deviceKey = "this-device"
        authorityService.candidateList = [candidate]
        try await waitForPhase(.overview)

        context.send(viewAction: .compareCandidate(candidate))
        XCTAssertEqual(context.viewState.phase, .comparingCandidate)
        XCTAssertFalse(context.viewState.canSignGrant)

        context.send(viewAction: .signGrant)
        XCTAssertTrue(authorityService.grantedCandidates.isEmpty,
                      "The comparison is the only thing binding the key to the person holding the other phone.")

        context.hasComparedFingerprint = true
        XCTAssertTrue(context.viewState.canSignGrant)
        context.send(viewAction: .signGrant)
        try await waitForPhase(.enteringPin)
        context.pin = "123456"
        context.send(viewAction: .pinChanged)
        try await waitForPhase(.overview)

        XCTAssertEqual(authorityService.grantedCandidates, ["offered-key"])
    }

    // MARK: - Revocation

    func testRevokingAnotherDeviceIsOfferedOnlyWhileThisPhoneMayActAndNeverAgainstItself() async throws {
        let mine = device(key: "this-device", state: .active, quarantineUntil: nil, grantedSeq: 1)
        let theirs = device(key: "other-device", state: .active, quarantineUntil: nil, grantedSeq: 2)
        makeViewModel(chain: rootedChain(pending: nil, devices: [mine, theirs]))
        authorityService.deviceKey = "this-device"
        try await waitForPhase(.overview)

        XCTAssertTrue(context.viewState.canActAsAnAuthorityDevice)
        // Exactly two active devices: the carve-out of decision 5 applies and the screen says so rather
        // than hiding it.
        XCTAssertTrue(context.viewState.isInTheTwoDeviceCarveOut)

        context.send(viewAction: .revokeDevice(mine))
        XCTAssertTrue(authorityService.revocations.isEmpty,
                      "Removing this phone goes through the self-revocation, which is immediate and said so.")

        context.send(viewAction: .revokeDevice(theirs))
        try await waitForPhase(.enteringPin)
        context.pin = "123456"
        context.send(viewAction: .pinChanged)
        try await waitForPhase(.overview)

        XCTAssertEqual(authorityService.revocations.map(\.deviceKey), ["other-device"])
        XCTAssertEqual(authorityService.revocations.first?.reason, AuthorityRecord.reasonUnspecified,
                       "The account holder gave no reason and the app does not invent one.")
    }

    func testSelfRevocationRunsWithThisPhonesOwnKey() async throws {
        makeViewModel(chain: rootedChain(pending: nil,
                                         devices: [device(key: "this-device", state: .active, quarantineUntil: nil, grantedSeq: 1)]))
        authorityService.deviceKey = "this-device"
        try await waitForPhase(.overview)

        context.send(viewAction: .revokeThisDevice)
        try await waitForPhase(.enteringPin)
        context.pin = "123456"
        context.send(viewAction: .pinChanged)
        try await waitForPhase(.overview)

        XCTAssertEqual(authorityService.revocations.map(\.deviceKey), ["this-device"])
    }

    // MARK: - Recovery and the terminal state

    func testTheRecoveryFieldRefusesMaterialThatIsNotTheRightLengthBeforeAnythingIsSent() async throws {
        makeViewModel(chain: rootedChain(pending: nil))
        try await waitForPhase(.overview)

        context.send(viewAction: .startRecovery)
        XCTAssertEqual(context.viewState.phase, .enteringRecoveryArtifact)
        context.recoveryArtifact = "aaaa bbbb"
        XCTAssertFalse(context.viewState.canSubmitRecoveryArtifact)
        context.send(viewAction: .submitRecoveryArtifact)
        XCTAssertTrue(authorityService.typedArtifacts.isEmpty)

        context.recoveryArtifact = String(repeating: "a", count: AuthorityRecoveryArtifact.encodedLength)
        XCTAssertTrue(context.viewState.canSubmitRecoveryArtifact)
        context.send(viewAction: .submitRecoveryArtifact)
        try await waitForPhase(.enteringPin)
        context.pin = "123456"
        context.send(viewAction: .pinChanged)
        try await waitForPhase(.artifact)

        XCTAssertEqual(authorityService.typedArtifacts.count, 1)
        // A recovery mints a new recovery key, so the same shown-once rule applies as for adoption.
        XCTAssertEqual(context.viewState.artifactKind, .recoveryUnderRecoveryKey)
        XCTAssertNotNil(context.viewState.recoveryArtifact)
        XCTAssertFalse(context.viewState.canSubmitArtifact)

        context.hasStoredRecoveryArtifact = true
        context.send(viewAction: .submitArtifact)
        try await waitForPhase(.overview)
        XCTAssertEqual(authorityService.submittedKinds, [.recoveryUnderRecoveryKey])
    }

    func testTheAccountRecoveryPathIsAvailableToSomeoneWithNoKeyLeft() async throws {
        makeViewModel(chain: rootedChain(pending: nil))
        try await waitForPhase(.overview)

        context.send(viewAction: .startRecoveryThroughAccountRecovery)
        try await waitForPhase(.enteringPin)
        context.pin = "123456"
        context.send(viewAction: .pinChanged)
        try await waitForPhase(.artifact)

        XCTAssertEqual(context.viewState.artifactKind, .recoveryThroughAccountRecovery)
    }

    func testTheTerminalStateOffersNothing() async throws {
        makeViewModel(chain: AuthorityChainState(accountID: accountID,
                                                 accountClass: .bootstrap,
                                                 state: .authorityLost,
                                                 headSeq: 4,
                                                 headHash: String(repeating: "ab", count: 32),
                                                 devices: [],
                                                 pending: nil))
        try await waitForPhase(.overview)

        XCTAssertTrue(context.viewState.isAuthorityLost)
        // A second adoption authorized by login factors alone is the seizure this design refuses, so the
        // screen offers no way back.
        XCTAssertFalse(context.viewState.canAdopt)
        XCTAssertFalse(context.viewState.canActAsAnAuthorityDevice)

        context.send(viewAction: .startAdoption)
        XCTAssertTrue(authorityService.preparedStepUps.isEmpty)
    }

    // MARK: - Security alerts

    func testThisInstallCanBeRegisteredForAlertsAndRemovedWithNoFactor() async throws {
        makeViewModel(chain: rootedChain(pending: nil))
        authorityService.installationID = "this-install"
        try await waitForPhase(.overview)

        XCTAssertFalse(context.viewState.isRegisteredForAlerts)
        context.send(viewAction: .enableAlerts)
        let registered = deferFulfillment(context.observe(\.viewState.alerts)) { !$0.isEmpty }
        try await registered.fulfill()

        XCTAssertTrue(context.viewState.isRegisteredForAlerts)
        let own = try XCTUnwrap(context.viewState.alerts.first)
        XCTAssertTrue(context.viewState.isThisInstall(own))

        context.send(viewAction: .removeAlerts(own))
        let removed = deferFulfillment(context.observe(\.viewState.alerts)) { $0.isEmpty }
        try await removed.fulfill()

        XCTAssertEqual(authorityService.removedAlerts.map(\.installationID), ["this-install"])
        XCTAssertNil(authorityService.removedAlerts.first?.stepUp,
                     "The person holding this phone is the person the channel serves.")
    }

    func testRemovingAnotherInstallsAlertsAsksForAFactorFirst() async throws {
        makeViewModel(chain: rootedChain(pending: nil))
        authorityService.installationID = "this-install"
        authorityService.alerts = [SecurityNotificationSummary(installationID: "another-install",
                                                               platform: "APNS",
                                                               deviceLabel: "Old phone",
                                                               tokenFingerprint: "fingerprint",
                                                               isBoundToAnAuthorityDevice: true,
                                                               lastSeenAt: Date())]
        try await waitForPhase(.overview)

        let other = try XCTUnwrap(context.viewState.alerts.first)
        XCTAssertFalse(context.viewState.isThisInstall(other))

        context.send(viewAction: .removeAlerts(other))
        try await waitForPhase(.enteringPin)
        context.pin = "123456"
        context.send(viewAction: .pinChanged)
        try await waitForPhase(.overview)

        XCTAssertEqual(authorityService.removedAlerts.map(\.installationID), ["another-install"])
        XCTAssertEqual(authorityService.removedAlerts.first?.stepUp, .pin("123456"),
                       "The hold on that factor is what stops a just-recovered attacker emptying the channel.")
    }

    // MARK: - Helpers

    private static let assertion = PasskeyAssertion(id: "credential-id",
                                                    response: .init(clientDataJSON: "client-data",
                                                                    authenticatorData: "authenticator-data",
                                                                    signature: "signature",
                                                                    userHandle: nil))

    private static let passkeyOptions = PasskeyStepUpOptions(stepUpID: "step-up-id",
                                                             relyingPartyID: "gua.global",
                                                             challenge: Data([0x01]),
                                                             allowedCredentialIDs: [])

    private static func status(hasPin: Bool, passkeyRegistered: Bool) -> AccountSecurityStatus {
        AccountSecurityStatus(hasPin: hasPin,
                              passkeyRegistered: passkeyRegistered,
                              preferredFactor: passkeyRegistered ? .passkey : .pin,
                              phoneChangeStepUpFactors: [],
                              pinStepUpHoldRemainingSeconds: 0)
    }

    private func bootstrapChain() -> AuthorityChainState {
        AuthorityChainState(accountID: accountID,
                            accountClass: .bootstrap,
                            state: .bootstrap,
                            headSeq: 0,
                            headHash: String(repeating: "0", count: 64),
                            devices: [],
                            pending: nil)
    }

    private func rootedChain(pending: AuthorityPendingTransition?,
                             devices: [AuthorityDeviceSummary] = []) -> AuthorityChainState {
        AuthorityChainState(accountID: accountID,
                            accountClass: .bootstrap,
                            state: .rooted,
                            headSeq: 2,
                            headHash: String(repeating: "ab", count: 32),
                            devices: devices,
                            pending: pending)
    }

    private func device(key: String, state: AuthorityDeviceState, quarantineUntil: Date?, grantedSeq: Int64) -> AuthorityDeviceSummary {
        AuthorityDeviceSummary(deviceKey: key, label: "Device", state: state, quarantineUntil: quarantineUntil, grantedSeq: grantedSeq)
    }
}

// MARK: - Stubs

@MainActor
final class AuthorityServiceStub: AccountAuthorityServiceProtocol {
    var isEnabled = true
    var chain: AuthorityChainState?
    var deviceKey: String?
    var approvals: [AuthorityApproval] = []
    var signApprovalError: Error?
    var candidateList: [AuthorityCandidate] = []
    var alerts: [SecurityNotificationSummary] = []
    var installationID: String?
    var prepareError: Error?
    var offerError: Error?
    var opposeError: Error?
    var registerAlertsError: Error?

    private(set) var preparedStepUps: [AuthorityStepUp] = []
    private(set) var submissions = 0
    private(set) var submittedKinds: [PreparedAuthorityRecord.Kind] = []
    private(set) var signedApprovals: [String] = []
    private(set) var typedArtifacts: [String] = []
    private(set) var grantedCandidates: [String] = []
    private(set) var revocations: [(deviceKey: String, reason: UInt8)] = []
    private(set) var oppositions: [String] = []
    private(set) var opposedStepUps: [AuthorityStepUp?] = []
    private(set) var offers = 0
    private(set) var removedAlerts: [(installationID: String, stepUp: AuthorityStepUp?)] = []

    init(chain: AuthorityChainState?) {
        self.chain = chain
    }

    func state(accessToken: String) async throws -> AuthorityChainState {
        guard let chain else { throw IdentityServiceError.authority(.noAccount) }
        return chain
    }

    func prepareAdoption(accessToken: String,
                         accountID: AccountID,
                         stepUp: AuthorityStepUp) async throws -> PreparedAuthorityRecord {
        preparedStepUps.append(stepUp)
        if let prepareError { throw prepareError }
        return Self.prepared(kind: .adoption, accountID: accountID)
    }

    func prepareRecovery(accessToken: String,
                         state: AuthorityChainState,
                         typedArtifact: String,
                         stepUp: AuthorityStepUp) async throws -> PreparedAuthorityRecord {
        preparedStepUps.append(stepUp)
        typedArtifacts.append(typedArtifact)
        if let prepareError { throw prepareError }
        return Self.prepared(kind: .recoveryUnderRecoveryKey, accountID: state.accountID)
    }

    func prepareRecoveryThroughAccountRecovery(accessToken: String,
                                               state: AuthorityChainState,
                                               stepUp: AuthorityStepUp) async throws -> PreparedAuthorityRecord {
        preparedStepUps.append(stepUp)
        if let prepareError { throw prepareError }
        return Self.prepared(kind: .recoveryThroughAccountRecovery, accountID: state.accountID)
    }

    func submit(accessToken: String, prepared: PreparedAuthorityRecord) async throws -> AuthoritySubmission {
        guard prepared.isArtifactConfirmed else { throw AccountAuthorityServiceError.artifactUnconfirmed }
        submissions += 1
        submittedKinds.append(prepared.kind)
        return AuthoritySubmission(seq: 1, isPending: true, effectiveAt: Date().addingTimeInterval(259_200), recordHash: "hash")
    }

    func offerThisDevice(accessToken: String, accountID: AccountID) async throws -> AuthorityCandidate {
        if let offerError { throw offerError }
        offers += 1
        return AuthorityCandidate(deviceKeyB64: "offered-key",
                                  fingerprint: "ABCD2346",
                                  label: "iPhone",
                                  expiresAt: Date().addingTimeInterval(600))
    }

    func candidates(accessToken: String) async throws -> [AuthorityCandidate] {
        candidateList
    }

    func signDeviceGrant(accessToken: String,
                         state: AuthorityChainState,
                         candidate: AuthorityCandidate,
                         comparisonConfirmed: Bool,
                         stepUp: AuthorityStepUp) async throws -> AuthoritySubmission {
        preparedStepUps.append(stepUp)
        guard comparisonConfirmed else { throw AccountAuthorityServiceError.candidateUnverified }
        grantedCandidates.append(candidate.deviceKeyB64)
        return AuthoritySubmission(seq: state.headSeq + 1, isPending: false, effectiveAt: Date(), recordHash: "hash")
    }

    func revokeDevice(accessToken: String,
                      state: AuthorityChainState,
                      deviceKey: String,
                      reason: UInt8,
                      stepUp: AuthorityStepUp) async throws -> AuthoritySubmission {
        preparedStepUps.append(stepUp)
        revocations.append((deviceKey, reason))
        return AuthoritySubmission(seq: state.headSeq + 1, isPending: true, effectiveAt: Date(), recordHash: "hash")
    }

    func oppose(accessToken: String,
                state: AuthorityChainState,
                pending: AuthorityPendingTransition,
                stepUp: AuthorityStepUp?) async throws {
        if let opposeError { throw opposeError }
        oppositions.append(pending.recordHash)
        opposedStepUps.append(stepUp)
    }

    func registerSecurityAlerts(accessToken: String,
                                accountID: AccountID) async throws -> SecurityNotificationSummary {
        if let registerAlertsError { throw registerAlertsError }
        let summary = SecurityNotificationSummary(installationID: installationID ?? "install",
                                                  platform: "APNS",
                                                  deviceLabel: "iPhone",
                                                  tokenFingerprint: "fingerprint",
                                                  isBoundToAnAuthorityDevice: deviceKey != nil,
                                                  lastSeenAt: Date())
        alerts.append(summary)
        return summary
    }

    func securityAlerts(accessToken: String) async throws -> [SecurityNotificationSummary] {
        alerts
    }

    func removeSecurityAlerts(accessToken: String,
                              accountID: AccountID,
                              installationID: String,
                              stepUp: AuthorityStepUp?) async throws {
        removedAlerts.append((installationID, stepUp))
        alerts.removeAll { $0.installationID == installationID }
    }

    func thisInstallationID() -> String? {
        installationID
    }

    private static func prepared(kind: PreparedAuthorityRecord.Kind,
                                 accountID: AccountID) -> PreparedAuthorityRecord {
        PreparedAuthorityRecord(kind: kind,
                                accountID: accountID,
                                record: "record",
                                signature: "signature",
                                challenge: "challenge",
                                deviceLabel: "iPhone",
                                recoveryArtifact: "aaaa bbbb cccc")
    }

    func liveApprovals(accessToken: String) async throws -> [AuthorityApproval] {
        approvals
    }

    func signApproval(accessToken: String, approval: AuthorityApproval, state: AuthorityChainState) async throws {
        if let signApprovalError { throw signApprovalError }
        signedApprovals.append(approval.approvalID)
    }

    func thisDeviceKey(accountID: AccountID) -> String? {
        deviceKey
    }
}

@MainActor
final class PasskeyPresenterStub: PasskeyStepUpPresenting {
    private let result: Result<PasskeyAssertion, Error>
    private(set) var callCount = 0

    init(result: Result<PasskeyAssertion, Error>) {
        self.result = result
    }

    func assertion(for options: PasskeyStepUpOptions) async throws -> PasskeyAssertion {
        callCount += 1
        return try result.get()
    }
}
