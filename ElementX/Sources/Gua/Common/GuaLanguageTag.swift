//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation

extension Bundle {
    /// The app's language: "pt-BR", "es", "fr" or "en". Servers get this instead of the device locale, whose
    /// `pt-CA` or `pt-PT` match no server template. The bundled `pt` copy of pt-BR reports "pt-BR".
    static var guaAppLanguage: String {
        let language = (overrideLocalizations ?? app.preferredLocalizations).first ?? "en"
        return language == "pt" ? "pt-BR" : language
    }
}
