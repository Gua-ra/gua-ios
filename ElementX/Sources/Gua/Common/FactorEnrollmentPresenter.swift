//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import AuthenticationServices

/// How a web handoff ended, which the caller has no other way of knowing.
///
/// Told apart because they mean different things to whoever asked. A page that redirected back did what
/// it was opened for; a sheet the person closed did nothing, and reporting that as a success is the
/// "it worked" a reader knows is false.
enum WebHandoffOutcome: Equatable {
    /// The page redirected to this build's own callback, which is the only way it ends on its own.
    case returned
    /// The person closed the sheet. Nothing was proved and nothing was spent.
    case dismissed
}

/// Presents a web authentication session that drives factor enrollment, passkey or PIN, on the
/// IdP-hosted page returned by identity-service.
///
/// Both factors go through it for the same reason: a bearer session alone must never add a durable
/// factor, and the page is where the account is confirmed first.
///
/// A web authentication session is used (rather than `SFSafariViewController`) so
/// that the existing login session is available and the user doesn't have to sign
/// in again. The session finishes when the page redirects to the app's OIDC
/// redirect URL. Mirrors ``OIDCAccountSettingsPresenter``.
@MainActor
class FactorEnrollmentPresenter: NSObject {
    private let enrollURL: URL
    private let presentationAnchor: UIWindow
    private let oidcRedirectURL: URL
    /// Retained for the lifetime of the presentation so the session isn't cancelled early.
    private var session: ASWebAuthenticationSession?

    init(enrollURL: URL, presentationAnchor: UIWindow, appSettings: AppSettings) {
        self.enrollURL = enrollURL
        self.presentationAnchor = presentationAnchor
        oidcRedirectURL = appSettings.oidcRedirectURL
        super.init()
    }

    /// Presents the web authentication session and returns once it is dismissed —
    /// either because the page redirected to the callback URL or because the user
    /// closed the sheet.
    ///
    /// Throws if the IDP redirects back with an OIDC `error` parameter, or if
    /// `ASWebAuthenticationSession` fails for a reason other than user cancellation.
    /// User cancellation is not an error: it is reported as ``WebHandoffOutcome/dismissed``, so a
    /// caller that has something to say about it can, and enrollment, which re-reads the account's
    /// factors either way, can go on ignoring it.
    @discardableResult
    func start() async throws -> WebHandoffOutcome {
        // Pass the device locale so the IDP renders in the user's language (e.g. French).
        var urlToOpen = enrollURL
        if let languageCode = Locale.current.language.languageCode?.identifier,
           var components = URLComponents(url: enrollURL, resolvingAgainstBaseURL: true) {
            var queryItems = components.queryItems ?? []
            queryItems.append(URLQueryItem(name: "ui_locales", value: languageCode))
            components.queryItems = queryItems
            urlToOpen = components.url ?? enrollURL
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WebHandoffOutcome, Error>) in
            let session = ASWebAuthenticationSession(url: urlToOpen, callback: .oidcRedirectURL(oidcRedirectURL)) { callbackURL, error in
                if let error {
                    // Treat user-initiated cancellation as a normal dismissal (no error to surface).
                    if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                        continuation.resume(returning: .dismissed)
                    } else {
                        continuation.resume(throwing: error)
                    }
                } else if let callbackURL,
                          let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                          let errorCode = components.queryItems?.first(where: { $0.name == "error" })?.value {
                    // IDP redirected back with an OIDC error (e.g. access_denied).
                    let description = components.queryItems?.first(where: { $0.name == "error_description" })?.value
                    let message = description ?? errorCode
                    continuation.resume(throwing: NSError(domain: "FactorEnrollment",
                                                          code: -1,
                                                          userInfo: [NSLocalizedDescriptionKey: message]))
                } else if callbackURL != nil {
                    continuation.resume(returning: .returned)
                } else {
                    // No callback and no error at all. Whatever that is, it is not the redirect, so it is
                    // not reported as one: the safe direction here is the one that claims nothing.
                    continuation.resume(returning: .dismissed)
                }
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = self
            session.additionalHeaderFields = [
                "X-Element-User-Agent": UserAgentBuilder.makeASCIIUserAgent()
            ]
            self.session = session
            session.start()
        }
    }
}

// MARK: ASWebAuthenticationPresentationContextProviding

extension FactorEnrollmentPresenter: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        presentationAnchor
    }
}
