//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation

enum GuaPhoneNumber {
    private static let separators: Set<Character> = ["-", "(", ")", ".", "/"]

    /// Accepts the punctuation AutoFill supplies from Contacts, so a filled number is never refused.
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
