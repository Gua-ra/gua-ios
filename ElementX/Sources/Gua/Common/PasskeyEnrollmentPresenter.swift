//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import AuthenticationServices

/// Presents a web authentication session that drives passkey enrollment on the
/// IdP-hosted page returned by identity-service.
///
/// A web authentication session is used (rather than `SFSafariViewController`) so
/// that the existing login session is available and the user doesn't have to sign
/// in again. The session finishes when the page redirects to the app's OIDC
/// redirect URL. Mirrors ``OIDCAccountSettingsPresenter``.
@MainActor
class PasskeyEnrollmentPresenter: NSObject {
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
    func start() async {
        // Pass the device locale so the IDP renders in the user's language (e.g. French).
        // Append via percentEncodedQuery rather than `queryItems`: assigning queryItems
        // decodes and re-encodes the whole server-minted query, which turns an existing
        // %2B into a literal "+" — and OAuth/OIDC parsers read "+" as a space, corrupting
        // opaque state/hint values. The language code is bare ASCII, so no encoding needed.
        var urlToOpen = enrollURL
        if let languageCode = Locale.current.language.languageCode?.identifier,
           var components = URLComponents(url: enrollURL, resolvingAgainstBaseURL: true) {
            let localeParam = "ui_locales=\(languageCode)"
            components.percentEncodedQuery = [components.percentEncodedQuery, localeParam]
                .compactMap { $0 }
                .joined(separator: "&")
            urlToOpen = components.url ?? enrollURL
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let session = ASWebAuthenticationSession(url: urlToOpen, callback: .oidcRedirectURL(oidcRedirectURL)) { _, _ in
                continuation.resume()
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

extension PasskeyEnrollmentPresenter: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { presentationAnchor }
}
