//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation

enum GuaPhoneNumber {
    /// Whether the string is already the E.164 the identity service is given, which is a `+`
    /// followed by the country code and the national digits.
    ///
    /// Every screen that submits a number a person typed checks this first, because a number the
    /// server cannot read is not free: a reauthentication reserves one of the five attempts an
    /// account gets in an hour before it compares anything, and a number that is missing its
    /// country code can still parse against the server's default region and come back as the same
    /// neutral refusal a stranger's number gets. A handful of typos would then lock the account
    /// holder out of their own settings for an hour, with a refusal that by design cannot say the
    /// format was the problem.
    static func isE164(_ phone: String) -> Bool {
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("+") else { return false }
        let digits = trimmed.dropFirst()
        return digits.count >= 8 && digits.count <= 15 && digits.allSatisfy(\.isNumber)
    }
}
