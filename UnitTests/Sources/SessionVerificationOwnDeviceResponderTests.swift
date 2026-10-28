//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import XCTest

/// The responder screen for a request from another device of the same account.
@MainActor
final class SessionVerificationOwnDeviceResponderTests: XCTestCase {
    private var controller: SessionVerificationControllerProxyMock!
    private var cancellables = Set<AnyCancellable>()

    private let ownDeviceRequest = SessionVerificationRequestDetails(senderProfile: UserProfileProxy(userID: "@alice:gua.test"),
                                                                     flowID: "flow",
                                                                     deviceID: "WEB",
                                                                     deviceDisplayName: "Gua Web",
                                                                     firstSeenDate: .init(timeIntervalSince1970: 0))

    private let otherUserRequest = SessionVerificationRequestDetails(senderProfile: UserProfileProxy(userID: "@bob:gua.test"),
                                                                     flowID: "flow",
                                                                     deviceID: "BOBPHONE",
                                                                     deviceDisplayName: nil,
                                                                     firstSeenDate: .init(timeIntervalSince1970: 0))

    override func setUp() {
        cancellables.removeAll()
        controller = SessionVerificationControllerProxyMock.configureMock(requestDelay: .milliseconds(10))
        controller.acceptVerificationRequestReturnValue = .success(())
    }

    // MARK: - Starting the emoji check

    func testAcceptingAnOwnDeviceRequestStartsTheEmojiCheckWithoutAnotherTap() async throws {
        let viewModel = makeViewModel(flow: .deviceResponder(requestDetails: ownDeviceRequest))
        let context = viewModel.context
        let deferred = deferFulfillment(context.$viewState) { $0.verificationState == .showingChallenge(emojis: SessionVerificationControllerProxyMock.emojis) }

        // What the Start button on the request sends.
        context.send(viewAction: .acceptVerificationRequest)
        try await deferred.fulfill()

        XCTAssertEqual(controller.acceptVerificationRequestCallsCount, 1)
        XCTAssertEqual(controller.startSasVerificationCallsCount, 1)
    }

    func testAcceptingAnotherUsersRequestStillWaitsForStart() async throws {
        let viewModel = makeViewModel(flow: .userResponder(requestDetails: otherUserRequest))
        let context = viewModel.context
        let deferred = deferFulfillment(context.$viewState) { $0.verificationState == .verificationRequestAccepted }

        context.send(viewAction: .acceptVerificationRequest)
        try await deferred.fulfill()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(context.viewState.verificationState, .verificationRequestAccepted)
        XCTAssertEqual(controller.startSasVerificationCallsCount, 0)
    }

    func testOwnDeviceDoesNotStartTwiceWhenTheOtherSideStartedFirst() async throws {
        // The new device starts the emoji check before our accept call has returned.
        let actions = controller.actions
        controller.acceptVerificationRequestClosure = {
            actions.send(.startedSasVerification)
            try? await Task.sleep(for: .milliseconds(50))
            return .success(())
        }
        let viewModel = makeViewModel(flow: .deviceResponder(requestDetails: ownDeviceRequest))
        let context = viewModel.context

        context.send(viewAction: .acceptVerificationRequest)
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(context.viewState.verificationState, .sasVerificationStarted)
        XCTAssertEqual(controller.acceptVerificationRequestCallsCount, 1)
        XCTAssertEqual(controller.startSasVerificationCallsCount, 0)
    }

    // MARK: - Verified

    func testOwnDeviceConfirmationStaysOpenUntilDone() async throws {
        let viewModel = makeViewModel(flow: .deviceResponder(requestDetails: ownDeviceRequest),
                                      verificationState: .showingChallenge(emojis: SessionVerificationControllerProxyMock.emojis))
        let finishedCount = countFinished(viewModel)
        let deferred = deferFulfillment(viewModel.context.$viewState) { $0.verificationState == .verified }

        // What the "They match" button sends.
        viewModel.context.send(viewAction: .accept)
        try await deferred.fulfill()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(finishedCount(), 0)

        // What the Done button sends.
        viewModel.context.send(viewAction: .done)
        XCTAssertEqual(finishedCount(), 1)
    }

    func testAnotherUsersVerificationStillFinishesOnItsOwn() async throws {
        let viewModel = makeViewModel(flow: .userResponder(requestDetails: otherUserRequest),
                                      verificationState: .showingChallenge(emojis: SessionVerificationControllerProxyMock.emojis))
        let finishedCount = countFinished(viewModel)
        let deferred = deferFulfillment(viewModel.context.$viewState) { $0.verificationState == .verified }

        viewModel.context.send(viewAction: .accept)
        try await deferred.fulfill()

        XCTAssertEqual(finishedCount(), 1)
    }

    // MARK: - Ignore

    func testIgnoringAnOwnDeviceRequestReportsTheDevice() {
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

        // What the Ignore button sends.
        viewModel.context.send(viewAction: .ignoreVerificationRequest)

        XCTAssertEqual(actions, ["ignored WEB", "finished"])
    }

    func testIgnoringAnotherUsersRequestReportsNoDevice() {
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

        XCTAssertEqual(actions, ["finished"])
    }

    // MARK: - Copy

    func testOwnDeviceRequestCopy() {
        let flow = SessionVerificationScreenFlow.deviceResponder(requestDetails: ownDeviceRequest)

        XCTAssertEqual(state(.initial, flow).title, UntranslatedL10n.guaVerificationNewSignInTitle)
        XCTAssertEqual(state(.initial, flow).message, UntranslatedL10n.guaVerificationNewSignInSubtitle)
        XCTAssertEqual(state(.acceptingChallenge(emojis: []), flow).message, UntranslatedL10n.guaVerificationCompareEmojisSubtitle)
        XCTAssertEqual(state(.decliningChallenge(emojis: []), flow).message, UntranslatedL10n.guaVerificationCompareEmojisSubtitle)
        XCTAssertEqual(state(.verified, flow).message, UntranslatedL10n.guaVerificationCompleteOtherDeviceSubtitle)
    }

    func testOtherFlowsKeepTheirCopy() {
        let userFlow = SessionVerificationScreenFlow.userResponder(requestDetails: otherUserRequest)
        XCTAssertEqual(state(.initial, userFlow).title, L10n.screenSessionVerificationRequestTitle)
        XCTAssertEqual(state(.initial, userFlow).message, L10n.screenSessionVerificationUserResponderSubtitle)
        XCTAssertEqual(state(.acceptingChallenge(emojis: []), userFlow).message, L10n.screenSessionVerificationCompareEmojisSubtitle)

        XCTAssertEqual(state(.verified, .deviceInitiator).message, UntranslatedL10n.guaVerificationCompleteSubtitle)
    }

    func testOwnDeviceCopyNeverSaysSessionMatrixOrHomeserver() {
        let flow = SessionVerificationScreenFlow.deviceResponder(requestDetails: ownDeviceRequest)
        let states: [SessionVerificationScreenStateMachine.State] = [.initial, .acceptingVerificationRequest, .verificationRequestAccepted,
                                                                     .startingSasVerification, .sasVerificationStarted,
                                                                     .showingChallenge(emojis: []), .acceptingChallenge(emojis: []),
                                                                     .decliningChallenge(emojis: []), .verified, .cancelled]
        for verificationState in states {
            let viewState = state(verificationState, flow)
            let text = "\(viewState.title ?? "") \(viewState.message)".lowercased()
            for word in ["session", "matrix", "homeserver"] {
                XCTAssertFalse(text.contains(word), "\(verificationState) says \"\(word)\": \(text)")
            }
        }
    }

    // MARK: - Helpers

    private func makeViewModel(flow: SessionVerificationScreenFlow,
                               verificationState: SessionVerificationScreenStateMachine.State = .initial) -> SessionVerificationScreenViewModel {
        SessionVerificationScreenViewModel(sessionVerificationControllerProxy: controller,
                                           flow: flow,
                                           appSettings: AppSettings(),
                                           mediaProvider: MediaProviderMock(configuration: .init()),
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
