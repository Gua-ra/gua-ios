//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AuthenticationServices

/// Presents a web authentication session that will display the user's account settings page.
///
/// A web authentication session is used so that the same session used for login is available
/// meaning that the user doesn't need to sign in again. `SFSafariViewController` doesn't
/// have access to this session, and for some reason `prefersEphemeralWebBrowserSession`
/// isn't sharing the session back to Safari.
class OAuthAccountSettingsPresenter: NSObject {
    private let accountURL: URL
    private let redirectURL: URL
    private let presentationAnchor: UIWindow
    private let appMediator: AppMediatorProtocol
    private let presenterHook: OAuthAccountSettingsPresenterHookProtocol

    typealias Continuation = AsyncStream<Result<Void, OAuthError>>.Continuation
    private let continuation: Continuation?

    /// Retained for the lifetime of the presentation so the session isn't cancelled early.
    private var session: ASWebAuthenticationSession?

    /// GUA FORK: how the web sheet ended.
    nonisolated enum Outcome {
        /// The page navigated to the app's own scheme: whatever it was asked to do, it finished.
        case returned
        /// Closed by hand, or failed to present. Nothing on the page was completed.
        case dismissed
    }

    init(accountURL: URL,
         presentationAnchor: UIWindow,
         appMediator: AppMediatorProtocol,
         userSession: UserSessionProtocol,
         continuation: Continuation? = nil) {
        self.accountURL = accountURL
        redirectURL = userSession.userSettings.app.oAuthRedirectURL
        self.presentationAnchor = presentationAnchor
        self.appMediator = appMediator
        presenterHook = userSession.userHooks.oAuthAccountSettingsPresenterHook
        self.continuation = continuation

        super.init()
    }

    /// Presents a web authentication session for the supplied data.
    func start() {
        present(outcomeContinuation: nil)
    }

    /// GUA FORK: presents the web authentication session and resolves once the sheet is gone,
    /// saying whether the page came back to the app or was dismissed. Callers that need to act
    /// on the result of the web flow (e.g. the identity-reset approval) must `await` this before
    /// continuing, because the two endings are otherwise indistinguishable.
    func startAndWaitForOutcome() async -> Outcome {
        await withCheckedContinuation { (outcomeContinuation: CheckedContinuation<Outcome, Never>) in
            present(outcomeContinuation: outcomeContinuation)
        }
    }

    /// GUA FORK: closes the sheet from the app side.
    ///
    /// MAS's approval page never navigates to the callback URL, so the session has no reason to
    /// dismiss itself and the user is left reading "go back to the app" with only an X to press.
    /// Once we have established the approval landed, we close it for them.
    func dismiss() {
        session?.cancel()
        session = nil
    }

    private func present(outcomeContinuation: CheckedContinuation<Outcome, Never>?) {
        let accountURL = presenterHook.update(accountURL)

        let session = ASWebAuthenticationSession(url: accountURL, callback: .oAuthRedirectURL(redirectURL)) { [continuation] callbackURL, error in
            outcomeContinuation?.resume(returning: callbackURL == nil ? .dismissed : .returned)

            guard let continuation else { return }

            if error?.isOAuthUserCancellation == true {
                continuation.yield(.failure(.userCancellation))
            } else {
                let errorDescription = error.map(String.init(describing:)) ?? "Unknown error"
                MXLog.error("A web authentication session error occurred: \(errorDescription)")
                continuation.yield(.failure(.unknown))
            }

            continuation.finish()
        }

        session.prefersEphemeralWebBrowserSession = false
        session.presentationContextProvider = self
        session.additionalHeaderFields = [
            "X-Element-User-Agent": UserAgentBuilder.makeASCIIUserAgent(),
            "Accept-Language": Bundle.guaAppLanguage
        ]

        if accountURL.scheme == "https" || accountURL.scheme == "http" {
            self.session = session
            session.start()
        } else {
            appMediator.open(accountURL)
            // Opened outside the app, so no callback will ever report that the page came back.
            outcomeContinuation?.resume(returning: .dismissed)
        }
    }
}

// MARK: ASWebAuthenticationPresentationContextProviding

extension OAuthAccountSettingsPresenter: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        presentationAnchor
    }
}
