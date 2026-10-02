//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation

enum GuaPhoneNumber {
    /// Separators a person, or an address book, writes inside a number. They are dropped, not refused.
    private static let separators: Set<Character> = ["-", "(", ")", ".", "/"]

    /// The E.164 form sent to identity-service (`+`, country code, national digits), or `nil` when
    /// the text cannot be read as one.
    ///
    /// Every screen resolves a typed number here first, because a number the server cannot read still
    /// spends one of the account's limited reauth attempts. Accepts the punctuation AutoFill supplies
    /// from Contacts ("+1 (415) 555-0143"), so a filled number is never refused.
    static func e164(from phone: String) -> String? {
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("+") else { return nil }
        let rest = trimmed.dropFirst()
        guard rest.allSatisfy({ $0.isNumber || $0.isWhitespace || separators.contains($0) }) else { return nil }
        let digits = rest.filter(\.isNumber)
        guard digits.count >= 8, digits.count <= 15 else { return nil }
        return "+" + digits
    }

    static func isE164(_ phone: String) -> Bool {
        e164(from: phone) != nil
    }
}
