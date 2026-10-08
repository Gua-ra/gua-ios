//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import XCTest

@MainActor
class AppCoordinatorStateMachineTests: XCTestCase {
    private typealias State = AppCoordinatorStateMachine.State
    private typealias Event = AppCoordinatorStateMachine.Event

    private struct Transition {
        let from: State
        let event: Event?
        let to: State

        func removesAppLock(hasSessions: Bool) -> Bool {
            AppCoordinatorStateMachine.removesAppLock(from: from, event: event, to: to, hasSessions: hasSessions)
        }
    }

    private var stateMachine: AppCoordinatorStateMachine!
    private var transitions: [Transition] = []
    private var failedTransitionCount = 0

    private var signOutTransitions: [Transition] {
        transitions.filter {
            guard case .signOut = $0.event else { return false }
            return true
        }
    }

    override func setUp() {
        stateMachine = AppCoordinatorStateMachine()
        transitions = []
        failedTransitionCount = 0

        stateMachine.addTransitionHandler { [weak self] context in
            self?.transitions.append(Transition(from: context.fromState, event: context.event, to: context.toState))
        }
        stateMachine.addErrorHandler { [weak self] _ in
            self?.failedTransitionCount += 1
        }
    }

    func testSignOutRemovesTheAppLock() {
        stateMachine.processEvent(.startWithExistingSession)
        stateMachine.processEvent(.createdUserSession)
        XCTAssertEqual(stateMachine.state, .signedIn)

        stateMachine.processEvent(.signOut(isSoft: false))
        XCTAssertEqual(stateMachine.state, .signingOut(isSoft: false))

        stateMachine.processEvent(.completedSigningOut)
        XCTAssertEqual(stateMachine.state, .signedOut)
        XCTAssertEqual(transitions.last?.removesAppLock(hasSessions: false), true)
        XCTAssertEqual(transitions.last?.removesAppLock(hasSessions: true), true)
        XCTAssertEqual(transitions.filter { $0.removesAppLock(hasSessions: false) }.count, 1)
        XCTAssertEqual(failedTransitionCount, 0)
    }

    func testSoftSignOutKeepsTheAppLockUntilDataIsCleared() {
        stateMachine.processEvent(.startWithExistingSession)
        stateMachine.processEvent(.createdUserSession)

        stateMachine.processEvent(.signOut(isSoft: true))
        XCTAssertEqual(stateMachine.state, .signingOut(isSoft: true))

        stateMachine.processEvent(.showSoftLogout)
        XCTAssertEqual(stateMachine.state, .softLogout)
        XCTAssertFalse(transitions.contains { $0.removesAppLock(hasSessions: false) })

        stateMachine.processEvent(.signOut(isSoft: false))
        XCTAssertEqual(stateMachine.state, .signingOut(isSoft: false))

        stateMachine.processEvent(.completedSigningOut)
        XCTAssertEqual(stateMachine.state, .signedOut)
        XCTAssertEqual(transitions.last?.removesAppLock(hasSessions: false), true)
        XCTAssertEqual(failedTransitionCount, 0)
    }

    func testSignOutWhileSigningOutKeepsTheOriginalOptions() {
        stateMachine.processEvent(.startWithExistingSession)
        stateMachine.processEvent(.createdUserSession)
        stateMachine.processEvent(.signOut(isSoft: false))

        stateMachine.processEvent(.signOut(isSoft: true))
        XCTAssertEqual(stateMachine.state, .signingOut(isSoft: false))

        stateMachine.processEvent(.completedSigningOut)
        XCTAssertEqual(stateMachine.state, .signedOut)
        XCTAssertEqual(failedTransitionCount, 0)
    }

    func testSignOutWhenSignedOutRemovesTheAppLock() {
        stateMachine.processEvent(.startWithAuthentication)
        XCTAssertEqual(stateMachine.state, .signedOut)
        XCTAssertFalse(transitions.contains { $0.removesAppLock(hasSessions: false) })

        stateMachine.processEvent(.signOut(isSoft: false))
        XCTAssertEqual(stateMachine.state, .signedOut)
        XCTAssertEqual(signOutTransitions.count, 1)
        XCTAssertEqual(signOutTransitions.first?.from, .signedOut)
        XCTAssertEqual(signOutTransitions.first?.removesAppLock(hasSessions: true), true)
        XCTAssertEqual(failedTransitionCount, 0)

        stateMachine.processEvent(.createdUserSession)
        XCTAssertEqual(stateMachine.state, .signedIn)
    }

    func testFailedRestoreRemovesTheAppLockOnceNoSessionRemains() {
        stateMachine.processEvent(.startWithExistingSession)
        stateMachine.processEvent(.failedRestoringSession)
        XCTAssertEqual(stateMachine.state, .signedOut)
        XCTAssertEqual(transitions.last?.removesAppLock(hasSessions: false), true)
        XCTAssertEqual(transitions.last?.removesAppLock(hasSessions: true), false)
        XCTAssertEqual(failedTransitionCount, 0)
    }

    func testSignOutWhileRestoringSessionIsReplayedOnceRestored() {
        stateMachine.processEvent(.startWithExistingSession)
        XCTAssertEqual(stateMachine.state, .restoringSession)

        stateMachine.processEvent(.signOut(isSoft: false))
        XCTAssertEqual(stateMachine.state, .restoringSession)
        XCTAssertTrue(signOutTransitions.isEmpty)

        stateMachine.processEvent(.createdUserSession)
        XCTAssertEqual(stateMachine.state, .signingOut(isSoft: false))
        XCTAssertEqual(signOutTransitions.first?.from, .signedIn)

        stateMachine.processEvent(.completedSigningOut)
        XCTAssertEqual(stateMachine.state, .signedOut)
        XCTAssertEqual(failedTransitionCount, 0)
    }

    func testSignOutWhileRestoringSessionThatFails() {
        stateMachine.processEvent(.startWithExistingSession)
        stateMachine.processEvent(.signOut(isSoft: false))

        stateMachine.processEvent(.failedRestoringSession)
        XCTAssertEqual(stateMachine.state, .signedOut)
        XCTAssertEqual(signOutTransitions.count, 1)
        XCTAssertEqual(signOutTransitions.first?.from, .signedOut)
        XCTAssertEqual(signOutTransitions.first?.removesAppLock(hasSessions: true), true)
        XCTAssertEqual(failedTransitionCount, 0)
    }

    func testSignOutBeforeStartIsReplayedOnceStarted() {
        stateMachine.processEvent(.signOut(isSoft: false))
        XCTAssertEqual(stateMachine.state, .initial)
        XCTAssertTrue(transitions.isEmpty)

        stateMachine.processEvent(.startWithAuthentication)
        XCTAssertEqual(stateMachine.state, .signedOut)
        XCTAssertEqual(signOutTransitions.count, 1)
        XCTAssertEqual(signOutTransitions.first?.from, .signedOut)
        XCTAssertEqual(failedTransitionCount, 0)
    }
}
