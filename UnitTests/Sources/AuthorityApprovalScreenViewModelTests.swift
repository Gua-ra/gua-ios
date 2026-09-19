//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

@testable import ElementX
import XCTest

@MainActor
final class AuthorityApprovalScreenViewModelTests: XCTestCase {
    private var authorityService: AuthorityServiceStub!
    private var viewModel: AuthorityApprovalScreenViewModel!

    private var context: AuthorityApprovalScreenViewModelType.Context {
        viewModel.context
    }

    private var accountID: AccountID!

    override func setUpWithError() throws {
        accountID = try AccountID.derive(rootClass: AccountID.classBootstrap,
                                         canonicalBytes: [UInt8]("approval-account".utf8))
    }

    private func makeViewModel(approvals: [AuthorityApproval],
                               deviceState: AuthorityDeviceState = .active,
                               holdsKey: Bool = true) {
        let chain = AuthorityChainState(accountID: accountID,
                                        accountClass: .bootstrap,
                                        state: .rooted,
                                        headSeq: 1,
                                        headHash: String(repeating: "ab", count: 32),
                                        devices: [AuthorityDeviceSummary(deviceKey: "this-device",
                                                                         label: "iPhone",
                                                                         state: deviceState,
                                                                         quarantineUntil: nil,
                                                                         grantedSeq: 1)],
                                        pending: nil)
        authorityService = AuthorityServiceStub(chain: chain)
        authorityService.deviceKey = holdsKey ? "this-device" : nil
        authorityService.approvals = approvals
        let clientProxy = ClientProxyMock(.init())
        clientProxy.accessToken = "access-token"
        viewModel = AuthorityApprovalScreenViewModel(authorityService: authorityService,
                                                     clientProxy: clientProxy,
                                                     userIndicatorController: UserIndicatorControllerMock())
    }

    private func waitForPhase(_ phase: AuthorityApprovalScreenPhase) async throws {
        let deferred = deferFulfillment(context.observe(\.viewState.phase)) { $0 == phase }
        try await deferred.fulfill()
    }

    private static func approval(id: String, code: String, action: String?) -> AuthorityApproval {
        AuthorityApproval(approvalID: id,
                          code: code,
                          action: action,
                          actionDigest: GuaBase64URL.encode([UInt8](repeating: 0x01, count: 32)),
                          challenge: GuaBase64URL.encode([UInt8](repeating: 0x02, count: 32)),
                          expiresAt: Date().addingTimeInterval(600))
    }

    func testOneLiveApprovalIsShownWithItsCodeAndItsActionInWords() async throws {
        makeViewModel(approvals: [Self.approval(id: "one", code: "AB7K", action: "authority.device.grant")])
        try await waitForPhase(.approval)

        XCTAssertEqual(context.viewState.code, "AB7K")
        XCTAssertEqual(context.viewState.spacedCode, "A B 7 K")
        XCTAssertEqual(context.viewState.action, .addDevice)
        XCTAssertEqual(context.viewState.action.sentence, L10n.screenAuthorityApprovalActionAddDevice)
        XCTAssertTrue(context.viewState.canSign)
    }

    func testAnApprovalThisAppCannotDescribeIsNotSignable() async throws {
        // ADM-009 decision 6 has the approval name the action on a screen the page does not control. A
        // request this build has no words for cannot be named, so it cannot be approved here either.
        makeViewModel(approvals: [Self.approval(id: "one", code: "AB7K", action: "something.new")])
        try await waitForPhase(.approval)

        XCTAssertEqual(context.viewState.action, .undescribable)
        XCTAssertFalse(context.viewState.canSign)
        XCTAssertEqual(context.viewState.errorMessage, L10n.screenAuthorityApprovalUnknownAction)

        context.send(viewAction: .sign)
        XCTAssertTrue(authorityService.signedApprovals.isEmpty)
    }

    func testADeviceRefusesToPresentOneApprovalWhileAnotherIsLive() async throws {
        // With two codes live the reader can match the wrong screen, and matching is the whole of what
        // the code is for.
        makeViewModel(approvals: [Self.approval(id: "one", code: "AB7K", action: "authority.device.grant"),
                                  Self.approval(id: "two", code: "QP49", action: "authority.device.revoke")])
        try await waitForPhase(.tooManyLive)

        XCTAssertNil(context.viewState.approval)
        XCTAssertFalse(context.viewState.canSign)
    }

    func testNothingWaitingIsSaidPlainly() async throws {
        makeViewModel(approvals: [])
        try await waitForPhase(.empty)

        XCTAssertNil(context.viewState.approval)
    }

    func testADeviceHoldingNoAuthorityIsTold() async throws {
        makeViewModel(approvals: [Self.approval(id: "one", code: "AB7K", action: "authority.device.grant")],
                      holdsKey: false)
        try await waitForPhase(.unavailable)

        XCTAssertEqual(context.viewState.errorMessage, L10n.screenAuthorityApprovalNotAnAuthorityDevice)
        XCTAssertTrue(authorityService.signedApprovals.isEmpty)
    }

    func testAQuarantinedDeviceMayNotSignAnApproval() async throws {
        // A device inside its own grant window may not sign a grant, a revocation or an
        // authority-sensitive approval.
        makeViewModel(approvals: [Self.approval(id: "one", code: "AB7K", action: "authority.device.grant")],
                      deviceState: .quarantined)
        try await waitForPhase(.unavailable)

        XCTAssertTrue(authorityService.signedApprovals.isEmpty)
    }

    func testSigningSendsOneSignatureAndSaysSo() async throws {
        makeViewModel(approvals: [Self.approval(id: "one", code: "AB7K", action: "authority.device.revoke")])
        try await waitForPhase(.approval)

        XCTAssertEqual(context.viewState.action, .removeDevice)
        context.send(viewAction: .sign)
        try await waitForPhase(.signed)

        XCTAssertEqual(authorityService.signedApprovals, ["one"])
    }

    func testARefusedSignatureSendsTheReaderBackToTheOtherScreen() async throws {
        makeViewModel(approvals: [Self.approval(id: "one", code: "AB7K", action: "authority.device.grant")])
        try await waitForPhase(.approval)
        authorityService.signApprovalError = IdentityServiceError.authority(.approvalInvalid)

        context.send(viewAction: .sign)
        let deferred = deferFulfillment(context.observe(\.viewState.errorMessage)) { $0 != nil }
        try await deferred.fulfill()

        // The approval is burned on refusal as well as on acceptance, so there is nothing to retry here.
        XCTAssertEqual(context.viewState.errorMessage, L10n.screenAuthorityApprovalRefused)
        XCTAssertTrue(authorityService.signedApprovals.isEmpty)
    }
}
