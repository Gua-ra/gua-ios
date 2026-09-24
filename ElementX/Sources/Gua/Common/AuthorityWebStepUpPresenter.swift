//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import UIKit

/// GUA FORK: opens the web sheet an authority transition can take its step-up in, when the native
/// ceremony cannot run on this device (ADM-009 decision 4 step 2).
///
/// The fallback behind ``PasskeyStepUpPresenting``, not a replacement for it: the native assertion is
/// tried first wherever it works, because it is the same proof without a browser. What the sheet is for
/// is every device where it cannot be produced at all, which is a simulator, and a build whose
/// associated domains do not name the deployment it is talking to. On those, the only alternative to
/// this is asking a passkey-only account for a PIN it does not have, or telling it to add one to gain
/// authority, which ADM-009 forbids outright.
///
/// What comes back is only whether the page redirected. The proof is a row the server wrote against the
/// account, the session and the purpose, so there is no token here for this app to hold, hand on, or be
/// talked out of.
@MainActor
protocol AuthorityWebStepUpPresenting {
    /// Presents `url` in an authenticated web session and returns when it closes.
    func present(_ url: URL) async throws -> WebHandoffOutcome
}

@MainActor
final class AuthorityWebStepUpPresenter: AuthorityWebStepUpPresenting {
    private let presentationAnchor: UIWindow
    private let appSettings: AppSettings
    /// Retained for the lifetime of the presentation so the session is not torn down early.
    private var presenter: FactorEnrollmentPresenter?

    init(presentationAnchor: UIWindow, appSettings: AppSettings) {
        self.presentationAnchor = presentationAnchor
        self.appSettings = appSettings
    }

    func present(_ url: URL) async throws -> WebHandoffOutcome {
        // The enrollment sheet's own presenter, because this is the same handoff: one-time URL on the
        // sign-in origin, opened with the existing login session so nobody signs in twice, closed by a
        // redirect to this build's own scheme. The server builds both sessions in one place for the same
        // reason, and a second copy of this here would be a second place for the redirect rule to drift.
        let presenter = FactorEnrollmentPresenter(enrollURL: url,
                                                  presentationAnchor: presentationAnchor,
                                                  appSettings: appSettings)
        self.presenter = presenter
        defer { self.presenter = nil }
        return try await presenter.start()
    }
}
