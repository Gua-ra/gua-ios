//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import SwiftState

class AppCoordinatorStateMachine {
    /// States the AppCoordinator can find itself in
    enum State: StateType {
        /// The initial state, used before the AppCoordinator starts
        case initial
        /// Showing the authentication flow
        case signedOut
        /// Showing the soft logout flow
        case softLogout
        /// Opening an existing session.
        case restoringSession
                
        /// User session started
        case signedIn

        /// Processing a sign out request
        case signingOut(isSoft: Bool)
    }

    /// Events that can be triggered on the AppCoordinator state machine
    enum Event: EventType {
        /// Start the `AppCoordinator` by showing authentication.
        case startWithAuthentication
        
        /// Start the `AppCoordinator` by restoring an existing account.
        case startWithExistingSession
        
        /// Restoring session failed.
        case failedRestoringSession
        
        /// A session has been created.
        case createdUserSession
                
        /// Request sign out.
        case signOut(isSoft: Bool)
        /// Request the soft logout screen.
        case showSoftLogout
        /// Signing out completed.
        case completedSigningOut
        
        /// Request cache clearing.
        case clearCache
    }
    
    private let stateMachine: StateMachine<State, Event>
    
    /// A sign out received while the session is still being resolved, replayed once it is.
    private var heldSignOut: Event?
    
    var state: AppCoordinatorStateMachine.State {
        stateMachine.state
    }
    
    init() {
        stateMachine = StateMachine(state: .initial)
        configure()
    }

    private func configure() {
        stateMachine.addRoutes(event: .startWithAuthentication, transitions: [.initial => .signedOut])
        stateMachine.addRoutes(event: .createdUserSession, transitions: [.signedOut => .signedIn,
                                                                         .softLogout => .signedIn])
        stateMachine.addRoutes(event: .startWithExistingSession, transitions: [.initial => .restoringSession])
        stateMachine.addRoutes(event: .createdUserSession, transitions: [.restoringSession => .signedIn])
        stateMachine.addRoutes(event: .failedRestoringSession, transitions: [.restoringSession => .signedOut])
                
        stateMachine.addRoutes(event: .completedSigningOut, transitions: [.signingOut(isSoft: false) => .signedOut])
        stateMachine.addRoutes(event: .showSoftLogout, transitions: [.signingOut(isSoft: true) => .softLogout])
        
        stateMachine.addRoutes(event: .clearCache, transitions: [.signedIn => .initial])

        // Transitions with associated values need to be handled through `addRouteMapping`
        stateMachine.addRouteMapping { event, fromState, _ in
            switch (fromState, event) {
            case (.signingOut, .signOut):
                // A sign out in progress keeps the options it started with.
                return fromState
            case (.signedOut, .signOut):
                // There is no session to tear down, so the coordinator handles the request in place.
                return fromState
            case (_, .signOut(let isSoft)):
                return .signingOut(isSoft: isSoft)
            default:
                return nil
            }
        }

        addTransitionHandler { context in
            if let event = context.event {
                MXLog.info("Transitioning from `\(context.fromState)` to `\(context.toState)` with event `\(event)`")
            } else {
                MXLog.info("Transitioning from \(context.fromState)` to `\(context.toState)`")
            }
        }
    }
    
    /// Attempt to move the state machine to another state through an event
    /// It will either invoke the `transitionHandler` or the `errorHandler` depending on its current state
    func processEvent(_ event: Event) {
        if case .signOut = event, isResolvingSession {
            MXLog.info("Holding `\(event)` until the session is resolved")
            heldSignOut = event
            return
        }
        
        stateMachine.tryEvent(event)
        
        if !isResolvingSession, let heldSignOut {
            self.heldSignOut = nil
            processEvent(heldSignOut)
        }
    }
    
    /// Whether a transition leaves the device without an account, which also removes the app lock.
    static func removesAppLock(from fromState: State, event: Event?, to toState: State, hasSessions: @autoclosure () -> Bool) -> Bool {
        switch (fromState, event, toState) {
        case (.signingOut(isSoft: false), .completedSigningOut, .signedOut), (.signedOut, .signOut, .signedOut):
            true
        case (.restoringSession, .failedRestoringSession, .signedOut):
            // The store deletes a session that fails to restore.
            !hasSessions()
        default:
            false
        }
    }
    
    private var isResolvingSession: Bool {
        state == .initial || state == .restoringSession
    }
    
    /// Registers a callback for processing state machine transitions
    func addTransitionHandler(_ handler: @escaping StateMachine<State, Event>.Handler) {
        stateMachine.addAnyHandler(.any => .any, handler: handler)
    }
    
    /// Registers a callback for processing state machine errors
    func addErrorHandler(_ handler: @escaping StateMachine<State, Event>.Handler) {
        stateMachine.addErrorHandler(handler: handler)
    }
}
