//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation

extension Locale {
    /// Built from the language and region subtags: `identifier` uses an underscore the server cannot match
    /// and `identifier(.bcp47)` carries locale extensions.
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
