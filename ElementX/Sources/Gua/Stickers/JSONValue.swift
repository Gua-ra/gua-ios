//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Any JSON value, so content written by newer clients survives a rewrite unchanged.
nonisolated enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
    
    init?(jsonString: String?) {
        guard let data = jsonString?.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return nil
        }
        self = value
    }
    
    var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
    
    var objectValue: [String: JSONValue]? {
        if case .object(let object) = self {
            object
        } else {
            nil
        }
    }
    
    var arrayValue: [JSONValue]? {
        if case .array(let array) = self {
            array
        } else {
            nil
        }
    }
    
    var stringValue: String? {
        if case .string(let string) = self {
            string
        } else {
            nil
        }
    }
    
    var boolValue: Bool? {
        if case .bool(let bool) = self {
            bool
        } else {
            nil
        }
    }
    
    var intValue: Int64? {
        switch self {
        case .int(let int):
            int
        case .double(let double) where double.rounded() == double && abs(double) < 9_007_199_254_740_992:
            Int64(double)
        default:
            nil
        }
    }
}

nonisolated extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int64.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else {
            self = try .object(container.decode([String: JSONValue].self))
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let bool):
            try container.encode(bool)
        case .int(let int):
            try container.encode(int)
        case .double(let double):
            try container.encode(double)
        case .string(let string):
            try container.encode(string)
        case .array(let array):
            try container.encode(array)
        case .object(let object):
            try container.encode(object)
        }
    }
}
