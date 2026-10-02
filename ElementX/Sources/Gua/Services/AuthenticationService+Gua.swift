//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation

extension AuthenticationService {
    /// Reserved OIDC `login_hint` literal that asks the sign-in page to lead with a passkey, sent in
    /// place of a phone number. MAS forwards it verbatim and identity-service maps it to the `PASSKEY`
    /// session intent. A wire contract with identity-service and the sign-in page: change it there first.
    static let passkeyLoginHint = "passkey"
}
