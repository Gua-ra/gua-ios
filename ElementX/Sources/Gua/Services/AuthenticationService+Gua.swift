//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation

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
