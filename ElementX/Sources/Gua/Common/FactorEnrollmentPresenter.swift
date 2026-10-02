//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import AuthenticationServices

/// Presents the web authentication session that drives factor enrollment, passkey or PIN, on the
/// IdP-hosted page returned by identity-service. A web authentication session, not
/// `SFSafariViewController`, so the existing sign-in session is available. It finishes when the
/// page redirects to the app's OIDC redirect URL.
@MainActor
class FactorEnrollmentPresenter: NSObject {
    private let enrollURL: URL
    private let presentationAnchor: UIWindow
    private let oidcRedirectURL: URL
    /// Retained so the session is not cancelled early.
    private var session: ASWebAuthenticationSession?

    init(enrollURL: URL, presentationAnchor: UIWindow, appSettings: AppSettings) {
        self.enrollURL = enrollURL
        self.presentationAnchor = presentationAnchor
        oidcRedirectURL = appSettings.oidcRedirectURL
        super.init()
    }

    /// Returns once the session is dismissed, by the callback redirect or by the user closing the
    /// sheet. User cancellation returns normally. Throws if the IdP redirects back with an OIDC `error`
    /// parameter or the session fails for any other reason.
    func start() async throws {
        // Pass the device locale so the IdP renders in the user's language.
        var urlToOpen = enrollURL
        if let languageCode = Locale.current.language.languageCode?.identifier,
           var components = URLComponents(url: enrollURL, resolvingAgainstBaseURL: true) {
            var queryItems = components.queryItems ?? []
            queryItems.append(URLQueryItem(name: "ui_locales", value: languageCode))
            components.queryItems = queryItems
            urlToOpen = components.url ?? enrollURL
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let session = ASWebAuthenticationSession(url: urlToOpen, callback: .oidcRedirectURL(oidcRedirectURL)) { callbackURL, error in
                if let error {
                    if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: error)
                    }
                } else if let callbackURL,
                          let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                          let errorCode = components.queryItems?.first(where: { $0.name == "error" })?.value {
                    let description = components.queryItems?.first(where: { $0.name == "error_description" })?.value
                    let message = description ?? errorCode
                    continuation.resume(throwing: NSError(domain: "FactorEnrollment",
                                                          code: -1,
                                                          userInfo: [NSLocalizedDescriptionKey: message]))
                } else {
                    continuation.resume()
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
