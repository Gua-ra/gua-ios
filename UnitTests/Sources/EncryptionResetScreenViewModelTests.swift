//
// Copyright Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import MatrixRustSDK
import XCTest

@MainActor
class EncryptionResetScreenViewModelTests: XCTestCase {
    private var clientProxy: ClientProxyMock!
    private var resetGuard: IdentityResetGuardMock!
    private var handle: IdentityResetHandleSDKMock!
    private var indicators: UserIndicatorControllerMock!
    private var viewModel: EncryptionResetScreenViewModel!
    private var cancellables: Set<AnyCancellable> = []

    private static let userID = "@reset:gua.example"
    private static let ceiling: Duration = .milliseconds(150)

    override func setUp() {
        AppSettings.resetAllSettings()
        cancellables = []
        clientProxy = ClientProxyMock(.init(userID: Self.userID))
        clientProxy.accessToken = "access-token"
        let secureBackup = SecureBackupControllerMock()
        secureBackup.underlyingRecoveryState = CurrentValueSubject<SecureBackupRecoveryState, Never>(.disabled).asCurrentValuePublisher()
        clientProxy.underlyingSecureBackupController = secureBackup

        resetGuard = IdentityResetGuardMock()
        clientProxy.acquireIdentityResetGuardReturnValue = resetGuard

        handle = IdentityResetHandleSDKMock()
        handle.authTypeReturnValue = .oAuth(info: OAuthCrossSigningResetInfo(approvalUrl: "https://account.example.org/approve"))
        clientProxy.resetIdentityReturnValue = .success(handle)

        indicators = UserIndicatorControllerMock()
        makeViewModel(approved: true)
    }

    override func tearDown() {
        AppSettings.resetAllSettings()
        IdentityResetPendingStore.clear(for: Self.userID)
    }

    // MARK: - ordering

    func testTheSyncIsClaimedBeforeTheResetStartsAndTheGuardIsLeftToItself() async {
        var order: [String] = []
        clientProxy.acquireIdentityResetGuardClosure = { [resetGuard] in
            order.append("acquire")
            return resetGuard!
        }
        clientProxy.resetIdentityClosure = { [handle] in
            order.append("resetIdentity")
            return .success(handle)
        }
        resetGuard.runResetAuthClosure = { _, _ in
            order.append("runReset")
            return Task { .success(()) }
        }

        let finished = deferFulfillment(viewModel.actionsPublisher) { if case .resetFinished = $0 { true } else { false } }
        viewModel.context.send(viewAction: .reset)
        try? await finished.fulfill()

        XCTAssertEqual(order, ["acquire", "resetIdentity", "runReset"])
        XCTAssertEqual(resetGuard.releaseIfIdleCallsCount, 0, "a guard that ran the reset releases itself")
    }

    // MARK: - the UI ceiling

    func testTheCeilingReportsButDoesNotReleaseAndTheLandingIsReportedOnce() async {
        let signal = TestSignal()
        resetGuard.runResetAuthClosure = { _, _ in
            Task {
                await signal.wait()
                return .success(())
            }
        }
        var finishedCount = 0
        viewModel.actionsPublisher.sink { if case .resetFinished = $0 { finishedCount += 1 } }.store(in: &cancellables)

        viewModel.context.send(viewAction: .reset)
        try? await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(resetGuard.runResetAuthCallsCount, 1)
        XCTAssertEqual(resetGuard.releaseIfIdleCallsCount, 0, "the ceiling must not touch the guard")
        XCTAssertFalse(viewModel.context.viewState.isResetting, "the button comes back while the upload continues")
        XCTAssertEqual(finishedCount, 0)

        signal.fire()
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(finishedCount, 1)
        XCTAssertEqual(resetGuard.releaseIfIdleCallsCount, 0)
    }

    func testAFailureAfterTheCeilingIsNotALanding() async {
        let signal = TestSignal()
        resetGuard.runResetAuthClosure = { _, _ in
            Task {
                await signal.wait()
                return .failure(ClientProxyError.sdkError(NSError(domain: "test", code: 1)))
            }
        }
        var finishedCount = 0
        viewModel.actionsPublisher.sink { if case .resetFinished = $0 { finishedCount += 1 } }.store(in: &cancellables)

        viewModel.context.send(viewAction: .reset)
        try? await Task.sleep(for: .milliseconds(500))
        signal.fire()
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(finishedCount, 0)
        XCTAssertEqual(resetGuard.releaseIfIdleCallsCount, 0)
    }

    func testAPressDuringARunningUploadJoinsIt() async {
        let signal = TestSignal()
        resetGuard.inFlightReset = Task {
            await signal.wait()
            return .success(())
        }
        var finishedCount = 0
        viewModel.actionsPublisher.sink { if case .resetFinished = $0 { finishedCount += 1 } }.store(in: &cancellables)

        viewModel.context.send(viewAction: .reset)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(clientProxy.resetIdentityCallsCount, 0)

        signal.fire()
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(finishedCount, 1)
    }

    // MARK: - idle guard release

    func testNoHandleMeansTheResetLandedAndTheGuardIsReleased() async {
        clientProxy.resetIdentityReturnValue = .success(nil)

        let finished = deferFulfillment(viewModel.actionsPublisher) { if case .resetFinished = $0 { true } else { false } }
        viewModel.context.send(viewAction: .reset)
        try? await finished.fulfill()

        XCTAssertEqual(resetGuard.releaseIfIdleCallsCount, 1)
        XCTAssertEqual(resetGuard.runResetAuthCallsCount, 0)
    }

    func testAFailedResetIdentityReleasesTheGuard() async {
        clientProxy.resetIdentityReturnValue = .failure(.sdkError(NSError(domain: "test", code: 1)))

        viewModel.context.send(viewAction: .reset)
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(resetGuard.releaseIfIdleCallsCount, 1)
        XCTAssertFalse(viewModel.context.viewState.isResetting)
        XCTAssertEqual(resetGuard.runResetAuthCallsCount, 0)
    }

    func testADismissedApprovalSheetCancelsTheHandleAndReleasesTheGuard() async {
        makeViewModel(approved: false)
        var completion: PassthroughSubject<OIDCAccountSettingsPresenter.Outcome, Never>?
        let requested = deferFulfillment(viewModel.actionsPublisher) { action in
            if case let .requestOIDCAuthorisation(_, publisher) = action {
                completion = publisher
                return true
            }
            return false
        }

        viewModel.context.send(viewAction: .reset)
        try? await requested.fulfill()
        completion?.send(.dismissed)
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(handle.cancelCallsCount, 1)
        XCTAssertEqual(resetGuard.releaseIfIdleCallsCount, 1)
        XCTAssertEqual(resetGuard.runResetAuthCallsCount, 0)
        XCTAssertFalse(viewModel.context.viewState.isResetting)
    }

    func testTeardownOnlyAsksTheGuardToReleaseIfIdle() async {
        let signal = TestSignal()
        resetGuard.runResetAuthClosure = { _, _ in Task { await signal.wait(); return .success(()) } }
        viewModel.context.send(viewAction: .reset)
        try? await Task.sleep(for: .milliseconds(300))

        viewModel.stop()
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(resetGuard.releaseIfIdleCallsCount, 1)
        signal.fire()
    }

    // MARK: - helpers

    private func makeViewModel(approved: Bool) {
        viewModel = EncryptionResetScreenViewModel(clientProxy: clientProxy,
                                                   userIndicatorController: indicators,
                                                   approveReset: { _, _ in approved },
                                                   resetCallCeiling: Self.ceiling)
    }
}
