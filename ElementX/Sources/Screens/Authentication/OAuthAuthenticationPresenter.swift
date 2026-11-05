//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AuthenticationServices

/// GUA FORK: lets tests replace the web authentication session.
protocol OAuthAuthenticationPresenterProtocol: AnyObject {
    func authenticate(using oAuthData: OAuthAuthorizationDataProxy) async -> Result<UserSessionProtocol, AuthenticationServiceError>
    func handleUniversalLinkCallback(_ url: URL)
    func cancel()
}

/// Presents a web authentication session for an OAuth request.
///
/// In certain instances the URL may require opening an external app instead of using a WAS. Because of this
/// it is recommended to not encode the OAuth authentication within any state machines, as there is no guarantee
/// that any cancellations/failures will be communicated upwards.
class OAuthAuthenticationPresenter: NSObject, OAuthAuthenticationPresenterProtocol {
    private let authenticationService: AuthenticationServiceProtocol
    private let redirectURL: URL
    private let presentationAnchor: UIWindow
    private let appMediator: AppMediatorProtocol
    private let presenterHook: OAuthAuthenticationPresenterHookProtocol
    private let userIndicatorController: UserIndicatorControllerProtocol
    
    /// The data required to complete a request.
    struct Request {
        let session: ASWebAuthenticationSession
        var continuation: CheckedContinuation<Response, Never>?
    }
    
    struct Response {
        let url: URL?
        let isExternal: Bool
        let error: Error?
    }
    
    private var activeRequest: Request?
    
    init(authenticationService: AuthenticationServiceProtocol,
         redirectURL: URL,
         presentationAnchor: UIWindow,
         appMediator: AppMediatorProtocol,
         presenterHook: OAuthAuthenticationPresenterHookProtocol,
         userIndicatorController: UserIndicatorControllerProtocol) {
        self.authenticationService = authenticationService
        self.redirectURL = redirectURL
        self.presentationAnchor = presentationAnchor
        self.appMediator = appMediator
        self.presenterHook = presenterHook
        self.userIndicatorController = userIndicatorController
        super.init()
    }
    
    /// Presents a web authentication session for the supplied data.
    ///
    /// **Note:** The failure case cannot be relied upon as a signal that the authentication has ended.
    /// In particular if the authentication URL requires opening an external app, then the user may return
    /// to the app without completing (or cancelling) the authentication.
    func authenticate(using oAuthData: OAuthAuthorizationDataProxy) async -> Result<UserSessionProtocol, AuthenticationServiceError> {
        let authenticationURL = presenterHook.update(oAuthData.url, homeserver: oAuthData.homeserver)
        
        let response = await withCheckedContinuation { continuation in
            let session = ASWebAuthenticationSession(url: authenticationURL, callback: .oAuthRedirectURL(redirectURL)) { [weak self] url, error in
                MXLog.info("Handling callback from the session.")
                self?.resumeActiveRequest(with: Response(url: url, isExternal: false, error: error))
            }
            
            // GUA FORK: Use an ephemeral web session so the MAS session cookie is
            // NOT shared with Safari or persisted between logins. Upstream uses
            // `false` for SSO-style convenience, but for Gua's phone-OTP flow that
            // means MAS reuses its existing session cookie, short-circuits the
            // upstream authentication, and logs the user straight into whoever
            // authenticated last (never reaching identity-service). Ephemeral
            // guarantees a fresh, cookie-free authorization every time.
            session.prefersEphemeralWebBrowserSession = true
            session.presentationContextProvider = self
            session.additionalHeaderFields = [
                "X-Element-User-Agent": UserAgentBuilder.makeASCIIUserAgent(),
                "Accept-Language": Bundle.guaAppLanguage
            ]
            
            activeRequest = Request(session: session, continuation: continuation)
            
            if authenticationURL.scheme == "https" || authenticationURL.scheme == "http" {
                session.start()
            } else {
                appMediator.open(authenticationURL)
            }
        }
        
        if response.isExternal {
            // Manually dismiss the web authentication session if the login was completed outside of the app.
            // Note: This doesn't trigger a callback so no need to worry about the continuation being called twice.
            activeRequest?.session.cancel()
        }
        activeRequest = nil
        
        guard let url = response.url else {
            // Check for user cancellation (on the WAS sheet) to avoid showing an alert in that instance.
            if response.error?.isOAuthUserCancellation == true {
                // No need to show an error here, just abort and return a failure.
                await authenticationService.abortOAuthLogin(data: oAuthData)
                return .failure(.oAuthError(.userCancellation))
            }
            
            let errorDescription = response.error.map(String.init(describing:)) ?? "Unknown error"
            MXLog.error("Missing callback URL from the web authentication session: \(errorDescription)")
            
            showFailureIndicator()
            await authenticationService.abortOAuthLogin(data: oAuthData)
            return .failure(.oAuthError(.unknown))
        }
        
        // Exchanging the callback with the homeserver can be slow, so show the loading indicator while we wait (the modal has already been dismissed).
        startLoading(delay: .milliseconds(50)) // Small delay to handle a cancellation callback without the indicator showing.
        defer { stopLoading() }
        
        switch await authenticationService.loginWithOAuthCallback(url) {
        case .success(let userSession):
            return .success(userSession)
        case .failure(.oAuthError(.userCancellation)): // Check for user cancellation (on the MAS web page)
            // No need to show an error here, just return the failure.
            return .failure(.oAuthError(.userCancellation))
        case .failure(let error):
            MXLog.error("Error occurred: \(error)")
            showFailureIndicator()
            return .failure(error)
        }
    }
    
    /// This method will be used when the web authentication session redirects the user to an external
    /// authentication app. During normal use the redirect is handled automatically by the session's closure.
    func handleUniversalLinkCallback(_ url: URL) {
        guard activeRequest != nil else {
            MXLog.error("Failed to handle universal link callback. Missing request.")
            return
        }
        MXLog.info("Handling callback from a universal link.")
        resumeActiveRequest(with: Response(url: url, isExternal: true, error: nil))
    }
    
    func cancel() {
        activeRequest?.session.cancel()
        // GUA FORK: programmatically cancelling the session doesn't trigger a callback, so resume the waiting login here.
        resumeActiveRequest(with: Response(url: nil, isExternal: false, error: ASWebAuthenticationSessionError(.canceledLogin)))
        activeRequest = nil
    }
    
    private func resumeActiveRequest(with response: sending Response) {
        activeRequest?.continuation?.resume(returning: response)
        activeRequest?.continuation = nil
    }
    
    private var loadingIndicatorID: String {
        "\(Self.self)-Loading"
    }
    
    private var failureIndicatorID: String {
        "\(Self.self)-Failure"
    }
    
    private func startLoading(delay: Duration? = nil) {
        userIndicatorController.submitIndicator(UserIndicator(id: loadingIndicatorID,
                                                              type: .modal,
                                                              title: L10n.commonLoading,
                                                              persistent: true),
                                                delay: delay)
    }
    
    private func stopLoading() {
        userIndicatorController.retractIndicatorWithId(loadingIndicatorID)
    }
    
    private func showFailureIndicator() {
        userIndicatorController.submitIndicator(UserIndicator(id: failureIndicatorID,
                                                              type: .toast,
                                                              title: L10n.errorUnknown,
                                                              icon: \.close))
    }
}

// MARK: ASWebAuthenticationPresentationContextProviding

extension OAuthAuthenticationPresenter: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        presentationAnchor
    }
}

extension ASWebAuthenticationSession.Callback {
    static func oAuthRedirectURL(_ url: URL) -> Self {
        if url.scheme == "https", let host = url.host() {
            .https(host: host, path: url.path())
        } else if let scheme = url.scheme {
            .customScheme(scheme)
        } else {
            fatalError("Invalid OAuth redirect URL: \(url)")
        }
    }
}

// MARK: - Helpers

extension Error {
    var isOAuthUserCancellation: Bool {
        let nsError = self as NSError
        
        if nsError.domain == ASWebAuthenticationSessionErrorDomain,
           nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue,
           // If there's a failure reason then the cancellation wasn't made by the user.
           nsError.localizedFailureReason == nil {
            return true
        }
        
        return false
    }
}
