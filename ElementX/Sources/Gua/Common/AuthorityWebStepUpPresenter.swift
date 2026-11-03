//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import UIKit

@MainActor
protocol AuthorityWebStepUpPresenting {
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
        let presenter = FactorEnrollmentPresenter(enrollURL: url,
                                                  presentationAnchor: presentationAnchor,
                                                  appSettings: appSettings)
        self.presenter = presenter
        defer { self.presenter = nil }
        return try await presenter.start()
    }
}
