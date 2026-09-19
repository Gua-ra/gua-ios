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
                                        pending: AuthorityPendingTransition(type: "DEVICE_REVOKE",
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

    // MARK: - The recovery artifact

    func testAdoptionIsUnreachableUntilTheArtifactIsConfirmed() async throws {
        makeViewModel(chain: bootstrapChain())
        try await waitForPhase(.overview)
        context.send(viewAction: .startAdoption)
        try await waitForPhase(.enteringPin)
        context.pin = "123456"
        context.send(viewAction: .pinChanged)
        try await waitForPhase(.artifact)

        XCTAssertFalse(context.viewState.canSubmitAdoption)
        context.send(viewAction: .submitAdoption)
        XCTAssertEqual(authorityService.submissions, 0, "Nothing is submitted while the confirmation is off.")

        context.hasStoredRecoveryArtifact = true
        XCTAssertTrue(context.viewState.canSubmitAdoption)
        context.send(viewAction: .submitAdoption)
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
        context.send(viewAction: .submitAdoption)
        XCTAssertEqual(authorityService.submissions, 0)
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

    private(set) var preparedStepUps: [AuthorityStepUp] = []
    private(set) var submissions = 0
    private(set) var signedApprovals: [String] = []

    init(chain: AuthorityChainState?) {
        self.chain = chain
    }

    func state(accessToken: String) async throws -> AuthorityChainState {
        guard let chain else { throw IdentityServiceError.authority(.noAccount) }
        return chain
    }

    func prepareAdoption(accessToken: String, accountID: AccountID, stepUp: AuthorityStepUp) async throws -> PreparedAdoption {
        preparedStepUps.append(stepUp)
        return PreparedAdoption(accountID: accountID,
                                record: "record",
                                signature: "signature",
                                challenge: "challenge",
                                deviceLabel: "iPhone",
                                recoveryArtifact: "aaaa bbbb cccc")
    }

    func submitAdoption(accessToken: String, prepared: PreparedAdoption) async throws -> AuthoritySubmission {
        guard prepared.isArtifactConfirmed else { throw AccountAuthorityServiceError.artifactUnconfirmed }
        submissions += 1
        return AuthoritySubmission(seq: 1, isPending: true, effectiveAt: Date().addingTimeInterval(259_200), recordHash: "hash")
    }

    func signDeviceGrant(accessToken: String,
                         state: AuthorityChainState,
                         granteeKey: [UInt8],
                         label: String,
                         stepUp: AuthorityStepUp) async throws -> AuthoritySubmission {
        preparedStepUps.append(stepUp)
        return AuthoritySubmission(seq: state.headSeq + 1, isPending: false, effectiveAt: Date(), recordHash: "hash")
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
