//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation

enum GuaPhoneNumber {
    /// The separators a person, or their address book, puts inside a number. They are how a number
    /// is written down, never part of it, so they are dropped rather than refused.
    private static let separators: Set<Character> = ["-", "(", ")", ".", "/"]

    /// The E.164 the identity service is given, which is a `+` followed by the country code and the
    /// national digits, or `nil` when the text cannot be read as one.
    ///
    /// Every screen that submits a number a person typed resolves it here first, because a number
    /// the server cannot read is not free: a reauthentication reserves one of the five attempts an
    /// account gets in an hour before it compares anything, and a number that is missing its
    /// country code can still parse against the server's default region and come back as the same
    /// neutral refusal a stranger's number gets. A handful of typos would then lock the account
    /// holder out of their own settings for an hour, with a refusal that by design cannot say the
    /// format was the problem.
    ///
    /// What it must not do is refuse a number the server would have accepted. These fields declare
    /// `.textContentType(.telephoneNumber)`, so AutoFill fills them with the number exactly as
    /// Contacts stores it, punctuation and all ("+1 (415) 555-0143"). The server reads those, so
    /// the punctuation is stripped here and the digits are what travels: a screen that refuses what
    /// its own AutoFill button just offered leaves the account holder no way through at all.
    static func e164(from phone: String) -> String? {
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("+") else { return nil }
        let rest = trimmed.dropFirst()
        // Only digits and the ways of writing them apart are allowed through. Anything else is a
        // number this app cannot read, and guessing at it is how the wrong number gets sent.
        guard rest.allSatisfy({ $0.isNumber || $0.isWhitespace || separators.contains($0) }) else { return nil }
        let digits = rest.filter(\.isNumber)
        guard digits.count >= 8, digits.count <= 15 else { return nil }
        return "+" + digits
    }

    /// Whether the string names a number that can be sent. Kept for the screens that only ask the
    /// question, such as whether to enable a Continue button.
    static func isE164(_ phone: String) -> Bool {
        e164(from: phone) != nil
    }
}
