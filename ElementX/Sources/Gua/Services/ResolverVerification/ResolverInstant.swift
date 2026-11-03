//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// An instant as the resolver writes it, with the fraction truncated to milliseconds, never rounded.
struct ResolverInstant: Equatable {
    let epochMilliseconds: Int64
    let hasSubMillisecondDigits: Bool

    private static let pattern = try? Regex(#"^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]{1,9}))?Z$"#)

    init?(iso: String) {
        guard let pattern = Self.pattern, let match = iso.wholeMatch(of: pattern) else { return nil }
        func number(_ index: Int) -> Int64? {
            match.output[index].substring.flatMap { Int64($0) }
        }
        guard let year = number(1), let month = number(2), let day = number(3),
              let hour = number(4), let minute = number(5), let second = number(6),
              (1...12).contains(month), day >= 1, day <= Self.daysIn(month: month, year: year),
              hour < 24, minute < 60, second < 60 else {
            return nil
        }
        let fraction = match.output[7].substring.map(String.init) ?? ""
        guard let milliseconds = Int64(String((fraction + "000").prefix(3))) else { return nil }
        let seconds = Self.daysFromCivil(year: year, month: month, day: day) * 86400 + hour * 3600 + minute * 60 + second
        epochMilliseconds = seconds * 1000 + milliseconds
        hasSubMillisecondDigits = fraction.count > 3 && fraction.dropFirst(3).contains { $0 != "0" }
    }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar (Howard Hinnant's algorithm).
    private static func daysFromCivil(year: Int64, month: Int64, day: Int64) -> Int64 {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func daysIn(month: Int64, year: Int64) -> Int64 {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }
}
