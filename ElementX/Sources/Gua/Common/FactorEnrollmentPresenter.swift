//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import AuthenticationServices

/// Uses a web authentication session so the existing sign-in session is available.
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

    /// User cancellation returns normally; an OIDC `error` on the redirect throws.
    func start() async throws {
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
