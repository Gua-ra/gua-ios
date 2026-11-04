//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

extension Bundle {
    /// Sent to servers instead of the device locale, whose `pt-CA` or `pt-PT` match no server template.
    /// The bundled `pt` localization is a copy of pt-BR.
    static var guaAppLanguage: String {
        let language = (overrideLocalizations ?? app.preferredLocalizations).first ?? "en"
        return language == "pt" ? "pt-BR" : language
    }
}
