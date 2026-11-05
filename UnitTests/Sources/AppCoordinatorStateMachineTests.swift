//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

@MainActor
final class AppCoordinatorStateMachineTests {
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
    
    init() {
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
    
    @Test
    func signOutRemovesTheAppLock() {
        stateMachine.processEvent(.startWithExistingSession)
        stateMachine.processEvent(.createdUserSession)
        #expect(stateMachine.state == .signedIn)
        
        stateMachine.processEvent(.signOut(isSoft: false))
        #expect(stateMachine.state == .signingOut(isSoft: false))
        
        stateMachine.processEvent(.completedSigningOut)
        #expect(stateMachine.state == .signedOut)
        #expect(transitions.last?.removesAppLock(hasSessions: false) == true)
        #expect(transitions.last?.removesAppLock(hasSessions: true) == true)
        #expect(transitions.filter { $0.removesAppLock(hasSessions: false) }.count == 1)
        #expect(failedTransitionCount == 0)
    }
    
    @Test
    func softSignOutKeepsTheAppLockUntilDataIsCleared() {
        stateMachine.processEvent(.startWithExistingSession)
        stateMachine.processEvent(.createdUserSession)
        
        stateMachine.processEvent(.signOut(isSoft: true))
        #expect(stateMachine.state == .signingOut(isSoft: true))
        
        stateMachine.processEvent(.showSoftLogout)
        #expect(stateMachine.state == .softLogout)
        #expect(!(transitions.contains { $0.removesAppLock(hasSessions: false) }))
        
        stateMachine.processEvent(.signOut(isSoft: false))
        #expect(stateMachine.state == .signingOut(isSoft: false))
        
        stateMachine.processEvent(.completedSigningOut)
        #expect(stateMachine.state == .signedOut)
        #expect(transitions.last?.removesAppLock(hasSessions: false) == true)
        #expect(failedTransitionCount == 0)
    }
    
    @Test
    func signOutWhileSigningOutKeepsTheOriginalOptions() {
        stateMachine.processEvent(.startWithExistingSession)
        stateMachine.processEvent(.createdUserSession)
        stateMachine.processEvent(.signOut(isSoft: false))
        
        stateMachine.processEvent(.signOut(isSoft: true))
        #expect(stateMachine.state == .signingOut(isSoft: false))
        
        stateMachine.processEvent(.completedSigningOut)
        #expect(stateMachine.state == .signedOut)
        #expect(failedTransitionCount == 0)
    }
    
    @Test
    func signOutWhenSignedOutRemovesTheAppLock() {
        stateMachine.processEvent(.startWithAuthentication)
        #expect(stateMachine.state == .signedOut)
        #expect(!(transitions.contains { $0.removesAppLock(hasSessions: false) }))
        
        stateMachine.processEvent(.signOut(isSoft: false))
        #expect(stateMachine.state == .signedOut)
        #expect(signOutTransitions.count == 1)
        #expect(signOutTransitions.first?.from == .signedOut)
        #expect(signOutTransitions.first?.removesAppLock(hasSessions: true) == true)
        #expect(failedTransitionCount == 0)
        
        stateMachine.processEvent(.createdUserSession)
        #expect(stateMachine.state == .signedIn)
    }
    
    @Test
    func failedRestoreRemovesTheAppLockOnceNoSessionRemains() {
        stateMachine.processEvent(.startWithExistingSession)
        stateMachine.processEvent(.failedRestoringSession)
        #expect(stateMachine.state == .signedOut)
        #expect(transitions.last?.removesAppLock(hasSessions: false) == true)
        #expect(transitions.last?.removesAppLock(hasSessions: true) == false)
        #expect(failedTransitionCount == 0)
    }
    
    @Test
    func signOutWhileRestoringSessionIsReplayedOnceRestored() {
        stateMachine.processEvent(.startWithExistingSession)
        #expect(stateMachine.state == .restoringSession)
        
        stateMachine.processEvent(.signOut(isSoft: false))
        #expect(stateMachine.state == .restoringSession)
        #expect(signOutTransitions.isEmpty)
        
        stateMachine.processEvent(.createdUserSession)
        #expect(stateMachine.state == .signingOut(isSoft: false))
        #expect(signOutTransitions.first?.from == .signedIn)
        
        stateMachine.processEvent(.completedSigningOut)
        #expect(stateMachine.state == .signedOut)
        #expect(failedTransitionCount == 0)
    }
    
    @Test
    func signOutWhileRestoringSessionThatFails() {
        stateMachine.processEvent(.startWithExistingSession)
        stateMachine.processEvent(.signOut(isSoft: false))
        
        stateMachine.processEvent(.failedRestoringSession)
        #expect(stateMachine.state == .signedOut)
        #expect(signOutTransitions.count == 1)
        #expect(signOutTransitions.first?.from == .signedOut)
        #expect(signOutTransitions.first?.removesAppLock(hasSessions: true) == true)
        #expect(failedTransitionCount == 0)
    }
    
    @Test
    func signOutBeforeStartIsReplayedOnceStarted() {
        stateMachine.processEvent(.signOut(isSoft: false))
        #expect(stateMachine.state == .initial)
        #expect(transitions.isEmpty)
        
        stateMachine.processEvent(.startWithAuthentication)
        #expect(stateMachine.state == .signedOut)
        #expect(signOutTransitions.count == 1)
        #expect(signOutTransitions.first?.from == .signedOut)
        #expect(failedTransitionCount == 0)
    }
}
