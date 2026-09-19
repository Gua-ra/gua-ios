//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation

extension Locale {
    /// The `Accept-Language` tag that goes out with an identity-service call that texts something,
    /// which is what picks the language the SMS is written in.
    ///
    /// Built from the language subtags rather than taken from `identifier`, which is the ICU form:
    /// `pt_BR` carries an underscore, matches none of the server's template keys, and its primary
    /// tag is never reached either because the server splits on `-`. Every Brazilian account was
    /// therefore getting its codes in English. `identifier(.bcp47)` has the right separator but
    /// also carries the locale's extensions (`pt-BR-u-ca-gregory`), which costs the same fallback,
    /// so only the language and its region are kept.
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
