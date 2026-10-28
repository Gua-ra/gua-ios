//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// Finds the roster entries whose `member` block repeats an object key. Foundation's JSON decoder keeps the
/// last duplicate silently, and a signed object whose parse differs between readers must be refused, so the
/// raw document is scanned once before decoding.
enum StrictJSONScanner {
    /// Indices into the top-level `entries` array whose `member` object (at any depth) has a duplicate key,
    /// or `nil` when the document is not well formed JSON.
    static func entriesWithDuplicateMemberKeys(in data: Data) -> Set<Int>? {
        var reader = Reader(bytes: [UInt8](data))
        reader.skipWhitespace()
        guard reader.value() else { return nil }
        reader.skipWhitespace()
        guard reader.index == reader.bytes.count else { return nil }
        return reader.flagged
    }

    private enum PathComponent: Equatable {
        case key(String)
        case index(Int)
    }

    private struct Reader {
        let bytes: [UInt8]
        var index = 0
        var path = [PathComponent]()
        var flagged = Set<Int>()

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        var current: UInt8? {
            index < bytes.count ? bytes[index] : nil
        }

        mutating func skipWhitespace() {
            while let byte = current, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                index += 1
            }
        }

        mutating func value() -> Bool {
            switch current {
            case UInt8(ascii: "{"): return object()
            case UInt8(ascii: "["): return array()
            case UInt8(ascii: "\""): return string() != nil
            case UInt8(ascii: "t"): return literal("true")
            case UInt8(ascii: "f"): return literal("false")
            case UInt8(ascii: "n"): return literal("null")
            default: return number()
            }
        }

        mutating func object() -> Bool {
            index += 1
            var keys = Set<String>()
            var duplicate = false
            skipWhitespace()
            if current == UInt8(ascii: "}") {
                index += 1
                return true
            }
            while true {
                skipWhitespace()
                guard current == UInt8(ascii: "\""), let key = string() else { return false }
                if !keys.insert(key).inserted { duplicate = true }
                skipWhitespace()
                guard current == UInt8(ascii: ":") else { return false }
                index += 1
                skipWhitespace()
                path.append(.key(key))
                guard value() else { return false }
                path.removeLast()
                skipWhitespace()
                if current == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                guard current == UInt8(ascii: "}") else { return false }
                index += 1
                break
            }
            if duplicate, let entry = memberEntryIndex() { flagged.insert(entry) }
            return true
        }

        /// The entry index when the object being closed is `entries[i].member` or anything inside it.
        private func memberEntryIndex() -> Int? {
            guard path.count >= 3, path[0] == .key("entries"), case let .index(entry) = path[1],
                  path[2] == .key("member") else {
                return nil
            }
            return entry
        }

        mutating func array() -> Bool {
            index += 1
            skipWhitespace()
            if current == UInt8(ascii: "]") {
                index += 1
                return true
            }
            var position = 0
            while true {
                skipWhitespace()
                path.append(.index(position))
                guard value() else { return false }
                path.removeLast()
                position += 1
                skipWhitespace()
                if current == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                guard current == UInt8(ascii: "]") else { return false }
                index += 1
                return true
            }
        }

        /// The decoded string, so that two spellings of one key compare equal, as they do in the decoder.
        mutating func string() -> String? {
            index += 1
            var out = [UInt8]()
            while let byte = current {
                index += 1
                switch byte {
                case UInt8(ascii: "\""):
                    return String(decoding: out, as: UTF8.self)
                case UInt8(ascii: "\\"):
                    guard let escaped = current else { return nil }
                    index += 1
                    switch escaped {
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(escaped)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        guard let scalar = unicodeEscape() else { return nil }
                        out.append(contentsOf: Array(String(scalar).utf8))
                    default: return nil
                    }
                case 0x00..<0x20:
                    return nil
                default:
                    out.append(byte)
                }
            }
            return nil
        }

        /// The scalar of a `\u` escape whose `u` was just consumed, joining a surrogate pair.
        private mutating func unicodeEscape() -> Unicode.Scalar? {
            guard let high = hex4() else { return nil }
            guard (0xD800...0xDBFF).contains(high) else { return Unicode.Scalar(high) }
            guard index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else { return nil }
            index += 2
            guard let low = hex4(), (0xDC00...0xDFFF).contains(low) else { return nil }
            return Unicode.Scalar(0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00))
        }

        private mutating func hex4() -> UInt32? {
            guard index + 4 <= bytes.count else { return nil }
            var value: UInt32 = 0
            for byte in bytes[index..<index + 4] {
                guard let digit = hexDigit(byte) else { return nil }
                value = value << 4 | digit
            }
            index += 4
            return value
        }

        private func hexDigit(_ byte: UInt8) -> UInt32? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): UInt32(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): UInt32(byte - UInt8(ascii: "A") + 10)
            default: nil
            }
        }

        mutating func literal(_ text: String) -> Bool {
            let expected = Array(text.utf8)
            guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else {
                return false
            }
            index += expected.count
            return true
        }

        mutating func number() -> Bool {
            let start = index
            while let byte = current, byte == UInt8(ascii: "-") || byte == UInt8(ascii: "+") || byte == UInt8(ascii: ".")
                || byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) {
                index += 1
            }
            return index > start
        }
    }
}
