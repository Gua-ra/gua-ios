//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// The marker every photo or video of one send carries, so that receivers can show them as one stack.
nonisolated struct MediaBatch: Hashable, Sendable {
    static let contentKey = "global.gua.batch"
    static let sendLimit = 20
    
    private static let version = 1
    private static let acceptedCounts = 2...100
    private static let mediaMessageTypes: Set = ["m.image", "m.video"]
    
    let id: String
    let index: Int
    let count: Int
    
    var extraContentJSON: String {
        // The ID is restricted to characters that need no escaping.
        #"{"\#(Self.contentKey)":{"v":\#(Self.version),"id":"\#(id)","index":\#(index),"count":\#(count)}}"#
    }
    
    init(id: String, index: Int, count: Int) {
        self.id = id
        self.index = index
        self.count = count
    }
    
    init?(eventJSON: String) {
        guard let event = try? JSONSerialization.jsonObject(with: Data(eventJSON.utf8)) as? [String: Any],
              let content = event["content"] as? [String: Any] else {
            return nil
        }
        self.init(content: content)
    }
    
    init?(content: [String: Any]) {
        guard let messageType = content["msgtype"] as? String, Self.mediaMessageTypes.contains(messageType),
              !Self.isReplacement(content),
              let marker = content[Self.contentKey] as? [String: Any],
              Self.integer(marker["v"]) == Self.version,
              let id = marker["id"] as? String, Self.isValidID(id),
              let index = Self.integer(marker["index"]),
              let count = Self.integer(marker["count"]),
              Self.acceptedCounts.contains(count), (0..<count).contains(index) else {
            return nil
        }
        
        self.init(id: id, index: index, count: count)
    }
    
    static func makeBatch(count: Int) -> [MediaBatch] {
        let id = UUID().uuidString.lowercased()
        return (0..<count).map { MediaBatch(id: id, index: $0, count: count) }
    }
    
    private static func isReplacement(_ content: [String: Any]) -> Bool {
        (content["m.relates_to"] as? [String: Any])?["rel_type"] as? String == "m.replace"
    }
    
    private static func isValidID(_ id: String) -> Bool {
        id.wholeMatch(of: #/[A-Za-z0-9._-]{1,64}/#) != nil
    }
    
    /// `JSONSerialization` bridges booleans and float literals such as `1.0` to `NSNumber` too, so only integer encodings count.
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              integerEncodings.contains(String(cString: number.objCType)) else {
            return nil
        }
        return number.intValue
    }
    
    private static let integerEncodings: Set = ["s", "i", "l", "q", "S", "I", "L", "Q"]
}
