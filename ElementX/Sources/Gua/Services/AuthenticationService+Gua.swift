//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation
import os

extension AuthenticationService {
    /// The reserved OIDC `login_hint` value that asks the sign-in page to lead with a passkey.
    ///
    /// The app sends it from the "Sign in with a passkey" button in place of a phone number, with
    /// `prompt` left at `login`. MAS forwards the hint verbatim and identity-service maps this
    /// literal to the session intent `PASSKEY` (surfaced to the page as `LoginState.intent`) rather
    /// than to a phone hint. The literal is a wire contract shared with identity-service and the
    /// sign-in page, so it changes there first, never here alone.
    static let passkeyLoginHint = "passkey"
}

/// GUA FORK: failures of the phone-entry sign-in steps, and the copy the screen shows for them.
enum GuaSignInError: Error {
    /// A step did not answer within `stepTimeout`.
    case timedOut

    static let stepTimeout: Duration = .seconds(30)

    static func message(for error: Error) -> String {
        switch error {
        // The resolver picked the account provider, so a client that cannot be built for it, or an
        // authorization URL that cannot be fetched from it, means the server did not answer.
        case GuaSignInError.timedOut, ResolverError.transport,
             AuthenticationServiceError.invalidHomeserverAddress, AuthenticationServiceError.oidcError(.urlFailure):
            UntranslatedL10n.guaSignInConnectionFailed
        case let error as ResolverError:
            error.userFacingMessage
        case AuthenticationServiceError.registrationNotSupported:
            UntranslatedL10n.guaResolverRegistrationClosed
        default:
            L10n.errorUnknown
        }
    }

    /// The value of `task`, or nil when `timeout` passes first. The task keeps running either way.
    static func value<T: Sendable>(of task: Task<T, Never>, within timeout: Duration) async -> T? {
        let isResumed = OSAllocatedUnfairLock(initialState: false)
        return await withCheckedContinuation { continuation in
            let resume: @Sendable (T?) -> Void = { value in
                let isFirst = isResumed.withLock { isResumed in
                    defer { isResumed = true }
                    return !isResumed
                }
                if isFirst {
                    continuation.resume(returning: value)
                }
            }
            let timer = Task {
                try? await Task.sleep(for: timeout)
                resume(nil)
            }
            Task {
                let value = await task.value
                timer.cancel()
                resume(value)
            }
        }
    }
}
