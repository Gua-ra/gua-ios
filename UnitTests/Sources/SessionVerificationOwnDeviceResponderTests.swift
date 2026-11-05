//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import Foundation
import Testing

@MainActor
final class SessionVerificationOwnDeviceResponderTests {
    private var controller: SessionVerificationControllerProxyMock!
    private var cancellables = Set<AnyCancellable>()
    
    private let ownDeviceRequest = SessionVerificationRequestDetails(senderProfile: UserProfile(userID: "@alice:gua.test"),
                                                                     flowID: "flow",
                                                                     deviceID: "WEB",
                                                                     deviceDisplayName: "Gua Web",
                                                                     firstSeenDate: .init(timeIntervalSince1970: 0))
    
    private let otherUserRequest = SessionVerificationRequestDetails(senderProfile: UserProfile(userID: "@bob:gua.test"),
                                                                     flowID: "flow",
                                                                     deviceID: "BOBPHONE",
                                                                     deviceDisplayName: nil,
                                                                     firstSeenDate: .init(timeIntervalSince1970: 0))
    
    init() {
        cancellables.removeAll()
        controller = SessionVerificationControllerProxyMock.configureMock(requestDelay: .milliseconds(10))
        let actions = controller.actions
        controller.acceptVerificationRequestClosure = {
            actions.send(.acceptedVerificationRequest)
            return .success(())
        }
    }
    
    // MARK: - Starting the emoji check
    
    @Test
    func acceptingAnOwnDeviceRequestStartsTheEmojiCheckWithoutAnotherTap() async throws {
        let viewModel = makeViewModel(flow: .deviceResponder(requestDetails: ownDeviceRequest))
        let context = viewModel.context
        let deferred = deferFulfillment(context.$viewState) { $0.verificationState == .showingChallenge(emojis: SessionVerificationControllerProxyMock.emojis) }
        
        context.send(viewAction: .acceptVerificationRequest)
        try await deferred.fulfill()
        
        #expect(controller.acceptVerificationRequestCallsCount == 1)
        #expect(controller.startSasVerificationCallsCount == 1)
    }
    
    @Test
    func acceptingAnotherUsersRequestAlsoStartsTheEmojiCheck() async throws {
        let viewModel = makeViewModel(flow: .userResponder(requestDetails: otherUserRequest))
        let context = viewModel.context
        let deferred = deferFulfillment(context.$viewState) { $0.verificationState == .showingChallenge(emojis: SessionVerificationControllerProxyMock.emojis) }
        
        context.send(viewAction: .acceptVerificationRequest)
        try await deferred.fulfill()
        
        #expect(controller.startSasVerificationCallsCount == 1)
    }
    
    @Test
    func ownDeviceDoesNotStartTwiceWhenTheOtherSideStartedFirst() async throws {
        let actions = controller.actions
        controller.acceptVerificationRequestClosure = {
            actions.send(.startedSasVerification)
            try? await Task.sleep(for: .milliseconds(50))
            actions.send(.acceptedVerificationRequest)
            return .success(())
        }
        let viewModel = makeViewModel(flow: .deviceResponder(requestDetails: ownDeviceRequest))
        let context = viewModel.context
        
        context.send(viewAction: .acceptVerificationRequest)
        try await Task.sleep(for: .milliseconds(200))
        
        #expect(context.viewState.verificationState == .sasVerificationStarted)
        #expect(controller.acceptVerificationRequestCallsCount == 1)
        #expect(controller.startSasVerificationCallsCount == 0)
    }
    
    // MARK: - Verified
    
    @Test
    func ownDeviceConfirmationStaysOpenUntilDone() async throws {
        let viewModel = makeViewModel(flow: .deviceResponder(requestDetails: ownDeviceRequest),
                                      verificationState: .showingChallenge(emojis: SessionVerificationControllerProxyMock.emojis))
        let finishedCount = countFinished(viewModel)
        let deferred = deferFulfillment(viewModel.context.$viewState) { $0.verificationState == .verified }
        
        viewModel.context.send(viewAction: .accept)
        try await deferred.fulfill()
        try await Task.sleep(for: .milliseconds(100))
        #expect(finishedCount() == 0)
        
        viewModel.context.send(viewAction: .done)
        #expect(finishedCount() == 1)
    }
    
    @Test
    func anotherUsersVerificationStillFinishesOnItsOwn() async throws {
        let viewModel = makeViewModel(flow: .userResponder(requestDetails: otherUserRequest),
                                      verificationState: .showingChallenge(emojis: SessionVerificationControllerProxyMock.emojis))
        let finishedCount = countFinished(viewModel)
        let deferred = deferFulfillment(viewModel.context.$viewState) { $0.verificationState == .verified }
        
        viewModel.context.send(viewAction: .accept)
        try await deferred.fulfill()
        
        #expect(finishedCount() == 1)
    }
    
    // MARK: - Ignore
    
    @Test
    func ignoringAnOwnDeviceRequestReportsTheDevice() {
        let viewModel = makeViewModel(flow: .deviceResponder(requestDetails: ownDeviceRequest))
        var actions: [String] = []
        viewModel.actions
            .sink { action in
                switch action {
                case .finished: actions.append("finished")
                case .ignoredOwnDeviceRequest(let deviceID): actions.append("ignored \(deviceID)")
                }
            }
            .store(in: &cancellables)
        
        viewModel.context.send(viewAction: .ignoreVerificationRequest)
        
        #expect(actions == ["ignored WEB", "finished"])
    }
    
    @Test
    func ignoringAnotherUsersRequestReportsNoDevice() {
        let viewModel = makeViewModel(flow: .userResponder(requestDetails: otherUserRequest))
        var actions: [String] = []
        viewModel.actions
            .sink { action in
                switch action {
                case .finished: actions.append("finished")
                case .ignoredOwnDeviceRequest(let deviceID): actions.append("ignored \(deviceID)")
                }
            }
            .store(in: &cancellables)
        
        viewModel.context.send(viewAction: .ignoreVerificationRequest)
        
        #expect(actions == ["finished"])
    }
    
    // MARK: - Copy
    
    @Test
    func ownDeviceRequestCopy() {
        let flow = SessionVerificationScreenFlow.deviceResponder(requestDetails: ownDeviceRequest)
        
        #expect(state(.initial, flow).title == UntranslatedL10n.guaVerificationNewSignInTitle)
        #expect(state(.initial, flow).message == UntranslatedL10n.guaVerificationNewSignInSubtitle)
        #expect(state(.acceptingChallenge(emojis: []), flow).message == UntranslatedL10n.guaVerificationCompareEmojisSubtitle)
        #expect(state(.decliningChallenge(emojis: []), flow).message == UntranslatedL10n.guaVerificationCompareEmojisSubtitle)
        #expect(state(.verified, flow).message == UntranslatedL10n.guaVerificationCompleteOtherDeviceSubtitle)
    }
    
    @Test
    func otherFlowsKeepTheirCopy() {
        let userFlow = SessionVerificationScreenFlow.userResponder(requestDetails: otherUserRequest)
        #expect(state(.initial, userFlow).title == L10n.screenSessionVerificationRequestTitle)
        #expect(state(.initial, userFlow).message == L10n.screenSessionVerificationUserResponderSubtitle)
        #expect(state(.acceptingChallenge(emojis: []), userFlow).message == L10n.screenSessionVerificationCompareEmojisSubtitle)
        
        #expect(state(.verified, .deviceInitiator).message == UntranslatedL10n.guaVerificationCompleteSubtitle)
    }
    
    @Test
    func ownDeviceCopyNeverSaysSessionMatrixOrHomeserver() {
        let flow = SessionVerificationScreenFlow.deviceResponder(requestDetails: ownDeviceRequest)
        let states: [SessionVerificationScreenStateMachine.State] = [.initial, .acceptingVerificationRequest, .verificationRequestAccepted,
                                                                     .startingSasVerification, .sasVerificationStarted,
                                                                     .showingChallenge(emojis: []), .acceptingChallenge(emojis: []),
                                                                     .decliningChallenge(emojis: []), .verified, .cancelled]
        for verificationState in states {
            let viewState = state(verificationState, flow)
            let text = "\(viewState.title ?? "") \(viewState.message)".lowercased()
            for word in ["session", "matrix", "homeserver"] {
                #expect(!text.contains(word), "\(verificationState) says \"\(word)\": \(text)")
            }
        }
    }
    
    // MARK: - Helpers
    
    private func makeViewModel(flow: SessionVerificationScreenFlow,
                               verificationState: SessionVerificationScreenStateMachine.State = .initial) -> SessionVerificationScreenViewModel {
        SessionVerificationScreenViewModel(sessionVerificationControllerProxy: controller,
                                           flow: flow,
                                           userSession: UserSessionMock(.init()),
                                           verificationState: verificationState)
    }
    
    private func countFinished(_ viewModel: SessionVerificationScreenViewModel) -> () -> Int {
        var count = 0
        viewModel.actions
            .sink { action in
                if case .finished = action {
                    count += 1
                }
            }
            .store(in: &cancellables)
        return { count }
    }
    
    private func state(_ verificationState: SessionVerificationScreenStateMachine.State, _ flow: SessionVerificationScreenFlow) -> SessionVerificationScreenViewState {
        SessionVerificationScreenViewState(flow: flow, learnMoreURL: URL(string: "https://gua.global")!, verificationState: verificationState)
    }
}
