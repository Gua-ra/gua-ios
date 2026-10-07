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
                               passkeyPresenter: PasskeyStepUpPresenting? = nil,
                               webPresenter: AuthorityWebStepUpPresenting? = nil) {
        authorityService = AuthorityServiceStub(chain: chain)
        let status = status ?? Self.status(hasPin: true, passkeyRegistered: false)
        let clientProxy = ClientProxyMock(.init())
        clientProxy.accessToken = "access-token"
        viewModel = AccountAuthorityScreenViewModel(authorityService: authorityService,
                                                    identityServiceClient: IdentityServiceClientMock(status: status,
                                                                                                     passkeyStepUpOptions: passkeyOptions),
                                                    clientProxy: clientProxy,
                                                    userIndicatorController: UserIndicatorControllerMock(),
                                                    passkeyStepUpPresenter: passkeyPresenter,
                                                    webStepUpPresenter: webPresenter)
    }

    private func waitForPhase(_ phase: AccountAuthorityScreenPhase) async throws {
        let deferred = deferFulfillment(context.observe(\.viewState.phase)) { $0 == phase }
        try await deferred.fulfill()
    }

    /// The objection flow starts and ends on the overview, so the phase cannot show that it ran.
    private func waitForObjections(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        var yields = 0
        while authorityService.opposedStepUps.count < count, yields < 500 {
            await Task.yield()
            yields += 1
        }
        XCTAssertEqual(authorityService.opposedStepUps.count, count, file: file, line: line)
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
        context.send(viewAction: .submitArtifact)
        XCTAssertEqual(authorityService.submissions, 0)
    }

    // MARK: - The passkey-only account

    func testAPasskeyOnlyAccountIsNeverToldToAddAPin() async throws {
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

    // MARK: - The web step-up

    func testAPasskeyThatCannotRunHereIsRunInTheWebSheetRatherThanAskingForThePin() async throws {
        let presenter = PasskeyPresenterStub(result: .failure(PasskeyStepUpError.unavailable))
        let web = WebStepUpPresenterStub(result: .success(.returned))
        makeViewModel(chain: bootstrapChain(),
                      status: Self.status(hasPin: true, passkeyRegistered: true),
                      passkeyOptions: Self.passkeyOptions,
                      passkeyPresenter: presenter,
                      webPresenter: web)
        try await waitForPhase(.overview)

        context.send(viewAction: .startAdoption)
        try await waitForPhase(.artifact)

        XCTAssertEqual(presenter.callCount, 1, "The native ceremony is still tried first.")
        XCTAssertEqual(authorityService.webStepUpPurposes, [.adopt])
        XCTAssertEqual(web.presentedURLs.count, 1)
        XCTAssertEqual(authorityService.preparedStepUps, [.webSheet])
        XCTAssertTrue(context.viewState.bindings.pin.isEmpty)
    }

    func testAPasskeyOnlyAccountGainsAuthorityThroughTheSheet() async throws {
        let web = WebStepUpPresenterStub(result: .success(.returned))
        makeViewModel(chain: bootstrapChain(),
                      status: Self.status(hasPin: false, passkeyRegistered: true),
                      passkeyOptions: Self.passkeyOptions,
                      passkeyPresenter: nil,
                      webPresenter: web)
        try await waitForPhase(.overview)

        context.send(viewAction: .startAdoption)
        try await waitForPhase(.artifact)

        XCTAssertEqual(authorityService.preparedStepUps, [.webSheet])
        XCTAssertNil(context.viewState.errorMessage)
    }

    func testClosingTheSystemSheetDoesNotOpenABrowser() async throws {
        let presenter = PasskeyPresenterStub(result: .failure(PasskeyStepUpError.cancelled))
        let web = WebStepUpPresenterStub(result: .success(.returned))
        makeViewModel(chain: bootstrapChain(),
                      status: Self.status(hasPin: true, passkeyRegistered: true),
                      passkeyOptions: Self.passkeyOptions,
                      passkeyPresenter: presenter,
                      webPresenter: web)
        try await waitForPhase(.overview)

        context.send(viewAction: .startAdoption)
        try await waitForPhase(.enteringPin)

        XCTAssertTrue(web.presentedURLs.isEmpty)
        XCTAssertTrue(authorityService.webStepUpPurposes.isEmpty)
    }

    func testAClosedSheetSpendsNothingAndClaimsNothing() async throws {
        let web = WebStepUpPresenterStub(result: .success(.dismissed))
        makeViewModel(chain: bootstrapChain(),
                      status: Self.status(hasPin: false, passkeyRegistered: true),
                      passkeyOptions: Self.passkeyOptions,
                      passkeyPresenter: nil,
                      webPresenter: web)
        try await waitForPhase(.overview)

        context.send(viewAction: .startAdoption)
        try await waitForPhase(.overview)

        XCTAssertEqual(web.presentedURLs.count, 1)
        XCTAssertTrue(authorityService.preparedStepUps.isEmpty)
        XCTAssertNil(context.viewState.errorMessage)
    }

    func testASheetThisDeploymentWillNotOpenLeavesThePinAsTheLastResort() async throws {
        let web = WebStepUpPresenterStub(result: .success(.returned))
        makeViewModel(chain: bootstrapChain(),
                      status: Self.status(hasPin: true, passkeyRegistered: true),
                      passkeyOptions: Self.passkeyOptions,
                      passkeyPresenter: PasskeyPresenterStub(result: .failure(PasskeyStepUpError.unavailable)),
                      webPresenter: web)
        authorityService.webStepUpResult = .failure(IdentityServiceError.authority(.disabled))
        try await waitForPhase(.overview)

        context.send(viewAction: .startAdoption)
        try await waitForPhase(.enteringPin)

        XCTAssertTrue(web.presentedURLs.isEmpty, "Nothing was opened, so nothing was shown.")
        context.pin = "123456"
        context.send(viewAction: .pinChanged)
        try await waitForPhase(.artifact)
        XCTAssertEqual(authorityService.preparedStepUps, [.pin("123456")])
    }

    func testAPasskeyOnlyAccountIsNeverSentToThePinWhenTheSheetFails() async throws {
        makeViewModel(chain: bootstrapChain(),
                      status: Self.status(hasPin: false, passkeyRegistered: true),
                      passkeyOptions: Self.passkeyOptions,
                      passkeyPresenter: PasskeyPresenterStub(result: .failure(PasskeyStepUpError.unavailable)),
                      webPresenter: WebStepUpPresenterStub(result: .success(.returned)))
        authorityService.webStepUpResult = .failure(IdentityServiceError.authority(.disabled))
        try await waitForPhase(.overview)

        context.send(viewAction: .startAdoption)
        let deferred = deferFulfillment(context.observe(\.viewState.errorMessage)) { $0 != nil }
        try await deferred.fulfill()

        XCTAssertEqual(context.viewState.errorMessage, L10n.screenAccountAuthorityErrorConfirmationIncomplete)
        XCTAssertEqual(context.viewState.phase, .overview, "The PIN screen is never reached.")
        XCTAssertTrue(authorityService.preparedStepUps.isEmpty)
    }

    func testAnAccountTheDeploymentCannotCheckIsToldSoRatherThanAskedToRetry() async throws {
        makeViewModel(chain: bootstrapChain(),
                      status: Self.status(hasPin: false, passkeyRegistered: true),
                      passkeyOptions: Self.passkeyOptions,
                      passkeyPresenter: PasskeyPresenterStub(result: .failure(PasskeyStepUpError.unavailable)),
                      webPresenter: WebStepUpPresenterStub(result: .success(.returned)))
        authorityService.webStepUpResult = .failure(IdentityServiceError.authority(.stepUpSheetUnavailable))
        try await waitForPhase(.overview)

        context.send(viewAction: .startAdoption)
        let deferred = deferFulfillment(context.observe(\.viewState.errorMessage)) { $0 != nil }
        try await deferred.fulfill()

        XCTAssertEqual(context.viewState.errorMessage, L10n.screenAccountAuthorityErrorStepUp)
        XCTAssertEqual(context.viewState.phase, .overview)
    }

    func testAProofTheServerWillNotSpendIsNotReportedAsAMissingFactor() async throws {
        makeViewModel(chain: bootstrapChain(),
                      status: Self.status(hasPin: false, passkeyRegistered: true),
                      passkeyOptions: Self.passkeyOptions,
                      passkeyPresenter: nil,
                      webPresenter: WebStepUpPresenterStub(result: .success(.returned)))
        authorityService.prepareError = IdentityServiceError.authority(.stepUpRequired)
        try await waitForPhase(.overview)

        context.send(viewAction: .startAdoption)
        let deferred = deferFulfillment(context.observe(\.viewState.errorMessage)) { $0 != nil }
        try await deferred.fulfill()

        XCTAssertEqual(authorityService.preparedStepUps, [.webSheet])
        XCTAssertEqual(context.viewState.errorMessage, L10n.screenAccountAuthorityErrorConfirmationIncomplete)
        XCTAssertNotEqual(context.viewState.errorMessage, L10n.screenAccountAuthorityErrorStepUp)
    }

    func testEachTransitionOpensASheetScopedToItsOwnPurpose() async throws {
        let revoking = device(key: "other-device", state: .active, quarantineUntil: nil, grantedSeq: 2)
        makeViewModel(chain: rootedChain(pending: nil,
                                         devices: [device(key: "this-device", state: .active, quarantineUntil: nil, grantedSeq: 1),
                                                   revoking]),
                      status: Self.status(hasPin: false, passkeyRegistered: true),
                      passkeyOptions: Self.passkeyOptions,
                      passkeyPresenter: nil,
                      webPresenter: WebStepUpPresenterStub(result: .success(.returned)))
        authorityService.deviceKey = "this-device"
        try await waitForPhase(.overview)

        context.send(viewAction: .revokeDevice(revoking))
        try await waitForPhase(.overview)
        XCTAssertEqual(authorityService.webStepUpPurposes, [.revoke])
        XCTAssertEqual(authorityService.revocations.map(\.deviceKey), ["other-device"])

        context.send(viewAction: .startRecoveryThroughAccountRecovery)
        try await waitForPhase(.artifact)
        XCTAssertEqual(authorityService.webStepUpPurposes, [.revoke, .recover])
        XCTAssertEqual(authorityService.preparedStepUps, [.webSheet, .webSheet])
    }

    func testTurningOffAnotherInstallsAlertsNeverOpensASheet() async throws {
        let web = WebStepUpPresenterStub(result: .success(.returned))
        makeViewModel(chain: rootedChain(pending: nil),
                      status: Self.status(hasPin: true, passkeyRegistered: true),
                      passkeyOptions: Self.passkeyOptions,
                      passkeyPresenter: PasskeyPresenterStub(result: .failure(PasskeyStepUpError.unavailable)),
                      webPresenter: web)
        authorityService.installationID = "this-install"
        authorityService.alerts = [SecurityNotificationSummary(installationID: "other-install",
                                                               platform: "APNS",
                                                               deviceLabel: "iPad",
                                                               tokenFingerprint: "fingerprint",
                                                               isBoundToAnAuthorityDevice: true,
                                                               lastSeenAt: Date())]
        try await waitForPhase(.overview)

        let row = try XCTUnwrap(context.viewState.alerts.first)
        context.send(viewAction: .removeAlerts(row))
        try await waitForPhase(.enteringPin)

        XCTAssertTrue(web.presentedURLs.isEmpty)
        XCTAssertTrue(authorityService.webStepUpPurposes.isEmpty)
    }

    // MARK: - Opposition

    func testAPendingAdoptionCanBeOpposedFromAnySession() async throws {
        makeViewModel(chain: rootedChain(pending: AuthorityPendingTransition(type: .adoptRoot,
                                                                             seq: 1,
                                                                             effectiveAt: Date().addingTimeInterval(259_200),
                                                                             recordHash: "adoption-hash")))
        try await waitForPhase(.overview)

        XCTAssertNil(context.viewState.thisDeviceKey)
        XCTAssertTrue(context.viewState.canOpposePending)

        context.send(viewAction: .opposePending)
        try await waitForPhase(.overview)

        XCTAssertEqual(authorityService.oppositions, ["adoption-hash"])
        XCTAssertEqual(authorityService.opposedStepUps, [nil], "The holds gate starting a transition, never opposing one.")
    }

    func testASecondObjectionAsksForTheFactorTheServerWantsAndIsThenMade() async throws {
        makeViewModel(chain: rootedChain(pending: AuthorityPendingTransition(type: .adoptRoot,
                                                                             seq: 1,
                                                                             effectiveAt: Date().addingTimeInterval(259_200),
                                                                             recordHash: "adoption-hash")),
                      status: Self.status(hasPin: true, passkeyRegistered: false),
                      webPresenter: WebStepUpPresenterStub(result: .success(.returned)))
        authorityService.opposeNeedsAStepUp = true
        try await waitForPhase(.overview)

        context.send(viewAction: .opposePending)
        try await waitForPhase(.enteringPin)
        XCTAssertNil(context.viewState.errorMessage, "A refusal that is being answered is not an error to read.")

        context.pin = "123456"
        context.send(viewAction: .pinChanged)
        try await waitForPhase(.overview)

        XCTAssertEqual(authorityService.opposedStepUps, [nil, .pin("123456")],
                       "The first attempt presents nothing and the retry presents the factor.")
        XCTAssertEqual(authorityService.oppositions, ["adoption-hash"])
        XCTAssertNil(context.viewState.errorMessage)
        XCTAssertTrue(authorityService.webStepUpPurposes.isEmpty)
    }

    func testAPasskeyHolderIsNotToldToSetUpAFactorToObjectASecondTime() async throws {
        let presenter = PasskeyPresenterStub(result: .success(Self.assertion))
        makeViewModel(chain: rootedChain(pending: AuthorityPendingTransition(type: .adoptRoot,
                                                                             seq: 1,
                                                                             effectiveAt: Date().addingTimeInterval(259_200),
                                                                             recordHash: "adoption-hash")),
                      status: Self.status(hasPin: false, passkeyRegistered: true),
                      passkeyOptions: Self.passkeyOptions,
                      passkeyPresenter: presenter)
        authorityService.opposeNeedsAStepUp = true
        try await waitForPhase(.overview)

        context.send(viewAction: .opposePending)
        try await waitForObjections(2)

        XCTAssertEqual(presenter.callCount, 1)
        XCTAssertEqual(authorityService.opposedStepUps,
                       [nil, .passkey(stepUpID: "step-up-id", assertion: Self.assertion)])
        XCTAssertEqual(authorityService.oppositions, ["adoption-hash"])
        XCTAssertNil(context.viewState.errorMessage)
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
        XCTAssertFalse(context.viewState.canSubmitRecoveryArtifact)

        context.recoveryArtifact = AuthorityRecoveryArtifact
            .render(Curve25519.Signing.PrivateKey())
        XCTAssertTrue(context.viewState.canSubmitRecoveryArtifact)
        context.send(viewAction: .submitRecoveryArtifact)
        try await waitForPhase(.enteringPin)
        context.pin = "123456"
        context.send(viewAction: .pinChanged)
        try await waitForPhase(.artifact)

        XCTAssertEqual(authorityService.typedArtifacts.count, 1)
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
        XCTAssertTrue(context.viewState.canRecoverThroughAccountRecovery)
    }

    func testTheAccountRecoveryPathIsNotOfferedOnAGenesisAccount() async throws {
        makeViewModel(chain: genesisRootedChain())
        try await waitForPhase(.overview)

        XCTAssertFalse(context.viewState.canRecoverThroughAccountRecovery)

        context.send(viewAction: .startRecoveryThroughAccountRecovery)
        for _ in 0..<50 {
            await Task.yield()
        }

        XCTAssertEqual(context.viewState.phase, .overview)
        XCTAssertTrue(authorityService.preparedStepUps.isEmpty)
        XCTAssertTrue(authorityService.webStepUpPurposes.isEmpty)
        XCTAssertTrue(authorityService.submittedKinds.isEmpty)
    }

    func testTheAccountRecoveryPathIsWithheldWhileThereIsNothingToReplaceOrSomethingPending() async throws {
        makeViewModel(chain: bootstrapChain())
        try await waitForPhase(.overview)
        XCTAssertFalse(context.viewState.canRecoverThroughAccountRecovery)

        let pending = AuthorityPendingTransition(type: .authorityRecovery,
                                                 seq: 3,
                                                 effectiveAt: Date().addingTimeInterval(259_200),
                                                 recordHash: "hash")
        makeViewModel(chain: rootedChain(pending: pending))
        try await waitForPhase(.overview)
        XCTAssertFalse(context.viewState.canRecoverThroughAccountRecovery)
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
        XCTAssertFalse(context.viewState.canAdopt)
        XCTAssertFalse(context.viewState.canActAsAnAuthorityDevice)

        context.send(viewAction: .startAdoption)
        XCTAssertTrue(authorityService.preparedStepUps.isEmpty)
    }

    // MARK: - Security alerts

    func testThisInstallCanBeRegisteredForAlertsAndRemovedAtTheOnePrice() async throws {
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
        try await waitForPhase(.enteringPin)
        XCTAssertTrue(authorityService.removedAlerts.isEmpty,
                      "Nothing is asked of the server before the factor the removal costs is presented.")

        context.pin = "123456"
        context.send(viewAction: .pinChanged)
        let removed = deferFulfillment(context.observe(\.viewState.alerts)) { $0.isEmpty }
        try await removed.fulfill()

        XCTAssertEqual(authorityService.removedAlerts.map(\.installationID), ["this-install"])
        XCTAssertEqual(authorityService.removedAlerts.first?.stepUp, .pin("123456"),
                       "The same step-up as every other authority action on this screen, own row included.")
    }

    func testAnAccountThatCannotPresentAFactorForARemovalIsToldSo() async throws {
        let web = WebStepUpPresenterStub(result: .success(.returned))
        makeViewModel(chain: rootedChain(pending: nil),
                      status: Self.status(hasPin: false, passkeyRegistered: true),
                      passkeyOptions: Self.passkeyOptions,
                      passkeyPresenter: PasskeyPresenterStub(result: .failure(PasskeyStepUpError.unavailable)),
                      webPresenter: web)
        authorityService.installationID = "this-install"
        authorityService.alerts = [SecurityNotificationSummary(installationID: "this-install",
                                                               platform: "APNS",
                                                               deviceLabel: "iPhone",
                                                               tokenFingerprint: "fingerprint",
                                                               isBoundToAnAuthorityDevice: true,
                                                               lastSeenAt: Date())]
        try await waitForPhase(.overview)

        let own = try XCTUnwrap(context.viewState.alerts.first)
        context.send(viewAction: .removeAlerts(own))
        let refused = deferFulfillment(context.observe(\.viewState.errorMessage)) { $0 != nil }
        try await refused.fulfill()

        XCTAssertEqual(context.viewState.errorMessage, L10n.screenAccountAuthorityErrorAlertsStepUp)
        XCTAssertTrue(web.presentedURLs.isEmpty, "There is no sheet for this step to be sent to.")
        XCTAssertTrue(authorityService.removedAlerts.isEmpty, "Nothing was asked of the server.")
        XCTAssertEqual(context.viewState.phase, .overview)
    }

    func testRemovingARowBoundToAnotherDeviceSaysWhoCanDoIt() async throws {
        makeViewModel(chain: rootedChain(pending: nil))
        authorityService.installationID = "this-install"
        authorityService.alerts = [SecurityNotificationSummary(installationID: "another-install",
                                                               platform: "APNS",
                                                               deviceLabel: "Old phone",
                                                               tokenFingerprint: "fingerprint",
                                                               isBoundToAnAuthorityDevice: true,
                                                               lastSeenAt: Date())]
        authorityService.removeAlertsError = IdentityServiceError.authority(.notificationDeviceRequired)
        try await waitForPhase(.overview)

        let other = try XCTUnwrap(context.viewState.alerts.first)
        context.send(viewAction: .removeAlerts(other))
        try await waitForPhase(.enteringPin)
        context.pin = "123456"
        context.send(viewAction: .pinChanged)
        let deferred = deferFulfillment(context.observe(\.viewState.errorMessage)) { $0 != nil }
        try await deferred.fulfill()

        XCTAssertEqual(context.viewState.errorMessage, L10n.screenAccountAuthorityErrorAlertsDeviceRequired)
    }

    func testADeploymentWithNoChannelIsNotOfferedOne() async throws {
        makeViewModel(chain: rootedChain(pending: nil))
        authorityService.installationID = "this-install"
        authorityService.securityAlertsError = IdentityServiceError.authority(.notificationsDisabled)
        try await waitForPhase(.overview)

        XCTAssertFalse(context.viewState.isAlertChannelAvailable)
        XCTAssertTrue(context.viewState.alerts.isEmpty)
    }

    func testAChannelThatFailedToAnswerIsNotReadAsAbsent() async throws {
        makeViewModel(chain: rootedChain(pending: nil))
        authorityService.installationID = "this-install"
        authorityService.securityAlertsError = IdentityServiceError.authority(.noAccount)
        try await waitForPhase(.overview)

        XCTAssertTrue(context.viewState.isAlertChannelAvailable)
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

    private func genesisRootedChain() -> AuthorityChainState {
        AuthorityChainState(accountID: accountID,
                            accountClass: .genesis,
                            state: .rooted,
                            headSeq: 2,
                            headHash: String(repeating: "ab", count: 32),
                            devices: [],
                            pending: nil)
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
    var opposeNeedsAStepUp = false
    var registerAlertsError: Error?
    var securityAlertsError: Error?
    var removeAlertsError: Error?
    var webStepUpResult: Result<URL, Error> = .success(URL(string: "https://auth.gua.test/login/enroll/token")!)

    private(set) var preparedStepUps: [AuthorityStepUp] = []
    private(set) var webStepUpPurposes: [AuthorityPurpose] = []
    private(set) var submissions = 0
    private(set) var submittedKinds: [PreparedAuthorityRecord.Kind] = []
    private(set) var signedApprovals: [String] = []
    private(set) var typedArtifacts: [String] = []
    private(set) var grantedCandidates: [String] = []
    private(set) var revocations: [(deviceKey: String, reason: UInt8)] = []
    private(set) var oppositions: [String] = []
    private(set) var opposedStepUps: [AuthorityStepUp?] = []
    private(set) var offers = 0
    private(set) var removedAlerts: [(installationID: String, stepUp: AuthorityStepUp)] = []

    init(chain: AuthorityChainState?) {
        self.chain = chain
    }

    func state(accessToken: String) async throws -> AuthorityChainState {
        guard let chain else { throw IdentityServiceError.authority(.noAccount) }
        return chain
    }

    func webStepUpURL(accessToken: String, purpose: AuthorityPurpose) async throws -> URL {
        webStepUpPurposes.append(purpose)
        return try webStepUpResult.get()
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

    func offerThisDevice(accessToken: String, state: AuthorityChainState) async throws -> AuthorityCandidate {
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
        opposedStepUps.append(stepUp)
        if opposeNeedsAStepUp, stepUp == nil {
            throw IdentityServiceError.authority(.stepUpRequired)
        }
        oppositions.append(pending.recordHash)
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
        if let securityAlertsError { throw securityAlertsError }
        return alerts
    }

    func removeSecurityAlerts(accessToken: String,
                              accountID: AccountID,
                              installationID: String,
                              stepUp: AuthorityStepUp) async throws {
        removedAlerts.append((installationID, stepUp))
        if let removeAlertsError { throw removeAlertsError }
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
final class WebStepUpPresenterStub: AuthorityWebStepUpPresenting {
    private let result: Result<WebHandoffOutcome, Error>
    private(set) var presentedURLs: [URL] = []

    init(result: Result<WebHandoffOutcome, Error>) {
        self.result = result
    }

    func present(_ url: URL) async throws -> WebHandoffOutcome {
        presentedURLs.append(url)
        return try result.get()
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
