//
// Copyright 2025 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

extension URLComponents {
    /// Appends to the raw query: `URLComponents.queryItems` re-serializes it and decodes `%2B` to a bare `+`,
    /// which corrupts the E.164 `login_hint`.
    mutating func appendUILocalesPreservingEncoding(languageCode: String? = Locale.current.language.languageCode?.identifier) {
        guard let languageCode, !languageCode.isEmpty else { return }

        appendQueryItemPreservingEncoding(name: "ui_locales", value: languageCode)
    }

    /// Tells MAS which account is signed in, because the sheet shares cookies with the system browser.
    mutating func appendAccountLoginHintPreservingEncoding(userID: String) {
        guard !userID.isEmpty else { return }
        appendQueryItemPreservingEncoding(name: "org.matrix.msc4198.login_hint", value: "mxid:\(userID)")
    }

    mutating func appendQueryItemPreservingEncoding(name: String, value: String) {
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .guaURLQueryValueAllowed) ?? name
        let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .guaURLQueryValueAllowed) ?? value
        let param = "\(encodedName)=\(encodedValue)"

        if let existing = percentEncodedQuery, !existing.isEmpty {
            percentEncodedQuery = existing + "&" + param
        } else {
            percentEncodedQuery = param
        }
    }
}

private extension CharacterSet {
    static let guaURLQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "+&=?#")
        return set
    }()
}
