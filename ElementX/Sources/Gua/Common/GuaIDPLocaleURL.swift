//
// Copyright 2025 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

extension URLComponents {
    /// Appends a `ui_locales` query parameter for the current device language so the IDP (MAS)
    /// renders in the user's language, **without disturbing the percent-encoding of the query
    /// that is already present**.
    ///
    /// Why not `queryItems.append(...)`: assigning through `URLComponents.queryItems` re-serializes
    /// the whole query and, in doing so, decodes an already-encoded `%2B` back to a bare `+`. A
    /// bare `+` in a query value is `application/x-www-form-urlencoded` shorthand for a space, so
    /// the downstream `login_hint=%2B<E.164>` that the SDK produced would arrive at MAS / idp-web as
    /// `login_hint=<space><digits>` — no longer a valid E.164. idp-web then fails to pre-fill and
    /// re-prompts for the phone number instead of jumping straight to the OTP step. Appending to the
    /// raw `percentEncodedQuery` string leaves the existing `%2B` (and every other escape) untouched.
    mutating func appendUILocalesPreservingEncoding(languageCode: String? = Locale.current.language.languageCode?.identifier) {
        guard let languageCode, !languageCode.isEmpty else { return }

        // Language codes are ASCII letters, so the encoding is effectively a passthrough, but it is
        // applied defensively.
        appendQueryItemPreservingEncoding(name: "ui_locales", value: languageCode)
    }

    /// Names the signed-in account to MAS with `org.matrix.msc4198.login_hint=mxid:<userID>`, for the
    /// same reason as above appended to the raw query rather than through `queryItems`.
    ///
    /// Account management opens in a sheet that shares cookies with the system browser, so without
    /// it the page can open under whichever account last signed in there. With it, MAS compares the
    /// hint with its browser session and asks for a sign-in as this account on a mismatch.
    mutating func appendAccountLoginHintPreservingEncoding(userID: String) {
        guard !userID.isEmpty else { return }
        appendQueryItemPreservingEncoding(name: "org.matrix.msc4198.login_hint", value: "mxid:\(userID)")
    }

    /// Appends one `name=value` pair to the percent-encoded query, leaving every existing escape as
    /// it is. Both halves are encoded as a query value: never a bare `+`, `&`, `=` that would be
    /// misread.
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
    /// Characters allowed unescaped in a single query-parameter **value** (RFC 3986 `query` minus the
    /// sub-delimiters that carry meaning inside a query string, plus `+` which a form-urlencoded
    /// parser would read as a space).
    static let guaURLQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "+&=?#")
        return set
    }()
}
