//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation

extension Bundle {
    /// The language the app's own screens are shown in: "pt-BR", "es", "fr" or "en".
    ///
    /// Everything the app hands to the server side speaks this language, so a web page opened from
    /// the app (`ui_locales`) and a text sent by identity-service (`Accept-Language`) match the screen
    /// that asked for them. The device locale is the wrong source: a Brazilian phone set to the Canada
    /// region reports `pt-CA`, and a Portuguese one reports `pt-PT`, neither of which the server has a
    /// template for, while the app shows both of them Brazilian Portuguese. It follows
    /// `overrideLocalizations` like `L10n` does, so tests see the language they set.
    static var guaAppLanguage: String {
        (overrideLocalizations ?? app.preferredLocalizations).first ?? "en"
    }
}
