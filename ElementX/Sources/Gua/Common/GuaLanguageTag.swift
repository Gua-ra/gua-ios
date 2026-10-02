//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation

extension Locale {
    /// The `Accept-Language` tag sent with identity-service calls that text something; it picks the
    /// language of the SMS.
    ///
    /// Built from the language and region subtags: `identifier` uses an underscore (`pt_BR`) the server
    /// cannot match, and `identifier(.bcp47)` carries locale extensions (`pt-BR-u-ca-gregory`).
    static func guaLanguageTag(for locale: Locale = .current) -> String? {
        guard let languageCode = locale.language.languageCode?.identifier, !languageCode.isEmpty else {
            return nil
        }
        guard let region = locale.language.region?.identifier, !region.isEmpty else {
            return languageCode
        }
        return "\(languageCode)-\(region)"
    }
}
