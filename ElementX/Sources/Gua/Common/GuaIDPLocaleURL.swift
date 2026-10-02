//
// Copyright 2025 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

extension URLComponents {
    /// Appends `ui_locales` for the device language so the IdP (MAS) renders in it.
    ///
    /// Appends to the raw query: `URLComponents.queryItems` re-serializes it and decodes `%2B` to a
    /// bare `+`, which a form-urlencoded parser reads as a space and which corrupts the E.164 `login_hint`.
    mutating func appendUILocalesPreservingEncoding(languageCode: String? = Locale.current.language.languageCode?.identifier) {
        guard let languageCode, !languageCode.isEmpty else { return }

        appendQueryItemPreservingEncoding(name: "ui_locales", value: languageCode)
    }

    /// Names the signed-in account to MAS with `org.matrix.msc4198.login_hint=mxid:<userID>`.
    ///
    /// Account management opens in a sheet that shares cookies with the system browser, so without the
    /// hint the page can open under whichever account last signed in there. With it, MAS asks for a
    /// sign-in as this account on a mismatch.
    mutating func appendAccountLoginHintPreservingEncoding(userID: String) {
        guard !userID.isEmpty else { return }
        appendQueryItemPreservingEncoding(name: "org.matrix.msc4198.login_hint", value: "mxid:\(userID)")
    }

    /// Appends one `name=value` pair to the percent-encoded query, leaving every existing escape as it is.
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
    /// Characters allowed unescaped in one query value: RFC 3986 `query` minus the delimiters that
    /// carry meaning inside a query string, and minus `+`, which a form-urlencoded parser reads as a space.
    static let guaURLQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "+&=?#")
        return set
    }()
}
