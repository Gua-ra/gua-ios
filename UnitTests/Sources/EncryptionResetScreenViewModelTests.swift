//
// Copyright Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import Foundation
import MatrixRustSDK
import MatrixRustSDKMocks
import Testing

@MainActor
final class EncryptionResetScreenViewModelTests {
    private var clientProxy: ClientProxyMock!
    private var resetGuard: IdentityResetGuardMock!
    private var handle: IdentityResetHandleSDKMock!
    private var indicators: UserIndicatorControllerMock!
    private var viewModel: EncryptionResetScreenViewModel!
    private var cancellables: Set<AnyCancellable> = []
    
    private static let userID = "@reset:gua.example"
    private static let ceiling: Duration = .milliseconds(150)
    
    init() {
        cancellables = []
        clientProxy = ClientProxyMock(.init(userID: Self.userID))
        clientProxy.accessToken = "access-token"
        let secureBackup = SecureBackupControllerMock()
        secureBackup.underlyingRecoveryState = CurrentValueSubject<SecureBackupRecoveryState, Never>(.disabled).asCurrentValuePublisher()
        clientProxy.underlyingSecureBackupController = secureBackup
        
        resetGuard = IdentityResetGuardMock()
        clientProxy.acquireIdentityResetGuardReturnValue = resetGuard
        
        handle = IdentityResetHandleSDKMock()
        handle.authTypeReturnValue = .oAuth(info: OAuthCrossSigningResetInfo(approvalUrl: "https://account.example.org/approve", session: "session_token"))
        clientProxy.resetIdentityReturnValue = .success(handle)
        
        indicators = UserIndicatorControllerMock()
        makeViewModel(approved: true)
    }
    
    isolated deinit {
        IdentityResetPendingStore.clear(for: Self.userID)
    }
    
    // MARK: - ordering
    
    @Test
    func theSyncIsClaimedBeforeTheResetStartsAndTheGuardIsLeftToItself() async {
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
        
        let finished = deferFulfillment(viewModel.actionsPublisher) {
            if case .resetFinished = $0 {
                true
            } else {
                false
            }
        }
        viewModel.context.send(viewAction: .reset)
        try? await finished.fulfill()
        
        #expect(order == ["acquire", "resetIdentity", "runReset"])
        #expect(resetGuard.releaseIfIdleCallsCount == 0, "a guard that ran the reset releases itself")
    }
    
    // MARK: - the UI ceiling
    
    @Test
    func theCeilingReportsButDoesNotReleaseAndTheLandingIsReportedOnce() async {
        let signal = TestSignal()
        resetGuard.runResetAuthClosure = { _, _ in
            Task {
                await signal.wait()
                return .success(())
            }
        }
        var finishedCount = 0
        viewModel.actionsPublisher.sink {
            if case .resetFinished = $0 {
                finishedCount += 1
            }
        }.store(in: &cancellables)
        
        viewModel.context.send(viewAction: .reset)
        try? await Task.sleep(for: .milliseconds(500))
        
        #expect(resetGuard.runResetAuthCallsCount == 1)
        #expect(resetGuard.releaseIfIdleCallsCount == 0, "the ceiling must not touch the guard")
        #expect(!viewModel.context.viewState.isResetting, "the button comes back while the upload continues")
        #expect(finishedCount == 0)
        
        signal.fire()
        try? await Task.sleep(for: .milliseconds(300))
        
        #expect(finishedCount == 1)
        #expect(resetGuard.releaseIfIdleCallsCount == 0)
    }
    
    @Test
    func aFailureAfterTheCeilingIsNotALanding() async {
        let signal = TestSignal()
        resetGuard.runResetAuthClosure = { _, _ in
            Task {
                await signal.wait()
                return .failure(ClientProxyError.sdkError(NSError(domain: "test", code: 1)))
            }
        }
        var finishedCount = 0
        viewModel.actionsPublisher.sink {
            if case .resetFinished = $0 {
                finishedCount += 1
            }
        }.store(in: &cancellables)
        
        viewModel.context.send(viewAction: .reset)
        try? await Task.sleep(for: .milliseconds(500))
        signal.fire()
        try? await Task.sleep(for: .milliseconds(300))
        
        #expect(finishedCount == 0)
        #expect(resetGuard.releaseIfIdleCallsCount == 0)
    }
    
    @Test
    func aPressDuringARunningUploadJoinsIt() async {
        let signal = TestSignal()
        resetGuard.inFlightReset = Task {
            await signal.wait()
            return .success(())
        }
        var finishedCount = 0
        viewModel.actionsPublisher.sink {
            if case .resetFinished = $0 {
                finishedCount += 1
            }
        }.store(in: &cancellables)
        
        viewModel.context.send(viewAction: .reset)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(clientProxy.resetIdentityCallsCount == 0)
        
        signal.fire()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(finishedCount == 1)
    }
    
    // MARK: - idle guard release
    
    @Test
    func noHandleMeansTheResetLandedAndTheGuardIsReleased() async {
        clientProxy.resetIdentityReturnValue = .success(nil)
        
        let finished = deferFulfillment(viewModel.actionsPublisher) {
            if case .resetFinished = $0 {
                true
            } else {
                false
            }
        }
        viewModel.context.send(viewAction: .reset)
        try? await finished.fulfill()
        
        #expect(resetGuard.releaseIfIdleCallsCount == 1)
        #expect(resetGuard.runResetAuthCallsCount == 0)
    }
    
    @Test
    func aFailedResetIdentityReleasesTheGuard() async {
        clientProxy.resetIdentityReturnValue = .failure(.sdkError(NSError(domain: "test", code: 1)))
        
        viewModel.context.send(viewAction: .reset)
        try? await Task.sleep(for: .milliseconds(300))
        
        #expect(resetGuard.releaseIfIdleCallsCount == 1)
        #expect(!viewModel.context.viewState.isResetting)
        #expect(resetGuard.runResetAuthCallsCount == 0)
    }
    
    @Test
    func aDismissedApprovalSheetCancelsTheHandleAndReleasesTheGuard() async {
        makeViewModel(approved: false)
        var completion: PassthroughSubject<OAuthAccountSettingsPresenter.Outcome, Never>?
        let requested = deferFulfillment(viewModel.actionsPublisher) { action in
            if case let .requestOAuthAuthorisation(_, publisher) = action {
                completion = publisher
                return true
            }
            return false
        }
        
        viewModel.context.send(viewAction: .reset)
        try? await requested.fulfill()
        completion?.send(.dismissed)
        try? await Task.sleep(for: .milliseconds(300))
        
        #expect(handle.cancelCallsCount == 1)
        #expect(resetGuard.releaseIfIdleCallsCount == 1)
        #expect(resetGuard.runResetAuthCallsCount == 0)
        #expect(!viewModel.context.viewState.isResetting)
    }
    
    @Test
    func teardownOnlyAsksTheGuardToReleaseIfIdle() async {
        let signal = TestSignal()
        resetGuard.runResetAuthClosure = { _, _ in Task { await signal.wait(); return .success(()) } }
        viewModel.context.send(viewAction: .reset)
        try? await Task.sleep(for: .milliseconds(300))
        
        viewModel.stop()
        try? await Task.sleep(for: .milliseconds(200))
        
        #expect(resetGuard.releaseIfIdleCallsCount == 1)
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
