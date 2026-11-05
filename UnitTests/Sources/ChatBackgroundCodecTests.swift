//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import XCTest

/// `chat-background-fixtures.json` is committed identically in gua-android, whose codec runs the same cases.
final class ChatBackgroundCodecTests: XCTestCase {
    func testSharedFixtures() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "chat-background-fixtures.json", withExtension: nil))
        let text = try String(contentsOf: url, encoding: .utf8)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        // The raw text keeps numbers such as 1.0 exactly as written, which reserialising would not.
        let contents = rawValues(forKey: "content", in: text)

        XCTAssertFalse(cases.isEmpty)
        XCTAssertEqual(cases.count, contents.count)

        for (fixture, content) in zip(cases, contents) {
            let name = try XCTUnwrap(fixture["name"] as? String)
            let expected = try background(fromExpected: XCTUnwrap(fixture["expected"] as? [String: Any]))
            XCTAssertEqual(ChatBackground(contentJSON: content), expected, name)
        }
    }

    func testUnreadableContentIsNoBackground() {
        XCTAssertEqual(ChatBackground(contentJSON: nil), .none)
        XCTAssertEqual(ChatBackground(contentJSON: ""), .none)
        XCTAssertEqual(ChatBackground(contentJSON: "{not json"), .none)
        XCTAssertEqual(ChatBackground(contentJSON: "\"aurora\""), .none)
    }

    func testPresetIsWrittenWithVersionAndKind() throws {
        let json = try jsonObject(ChatBackground.preset(.aurora).contentJSON)
        XCTAssertEqual(json as NSDictionary, ["v": 1, "kind": "preset", "preset": "aurora"] as NSDictionary)
    }

    func testRemovalIsWrittenAsEmptyContent() {
        XCTAssertEqual(ChatBackground.none.contentJSON, "{}")
    }

    func testPhotoIsWrittenRoundedAndReadsBack() throws {
        let photo = ChatBackground.Photo(url: "mxc://gua.global/AbCdEf",
                                         mimetype: "image/jpeg",
                                         width: 1536,
                                         height: 2048,
                                         size: 412_337,
                                         blurhash: "LKO2?U%2Tw=w]~RBVZRi};RPxuwH",
                                         dim: 0.351_234,
                                         alignX: 0.123_456,
                                         alignY: 1)
        let json = try jsonObject(ChatBackground.photo(photo).contentJSON)

        XCTAssertEqual(json["v"] as? Int, 1)
        XCTAssertEqual(json["kind"] as? String, "photo")
        XCTAssertNil(json["fallback_preset"])
        let written = try XCTUnwrap(json["photo"] as? [String: Any])
        XCTAssertEqual(written["url"] as? String, "mxc://gua.global/AbCdEf")
        XCTAssertEqual(written["mimetype"] as? String, "image/jpeg")
        XCTAssertEqual(written["w"] as? Int, 1536)
        XCTAssertEqual(written["h"] as? Int, 2048)
        XCTAssertEqual(written["size"] as? Int, 412_337)
        XCTAssertEqual(written["dim"] as? Int, 35)
        XCTAssertEqual(written["align"] as? NSDictionary, ["x": 123, "y": 1000] as NSDictionary)

        var rounded = photo
        rounded.dim = 0.35
        rounded.alignX = 0.123
        XCTAssertEqual(ChatBackground(contentJSON: ChatBackground.photo(photo).contentJSON), .photo(rounded))
    }

    func testPhotoIsWrittenInTheSharedFormat() {
        let photo = ChatBackground.Photo(url: "mxc://gua.global/AbCdEf",
                                         mimetype: "image/jpeg",
                                         width: 1536,
                                         height: 2048,
                                         size: 412_337,
                                         blurhash: "LKO2?U%2Tw=w]~RBVZRi};RPxuwH")
        XCTAssertEqual(ChatBackground.photo(photo).contentJSON,
                       #"{"kind":"photo","photo":{"align":{"x":500,"y":500},"blurhash":"LKO2?U%2Tw=w]~RBVZRi};RPxuwH","dim":35,"h":2048,"mimetype":"image/jpeg","size":412337,"url":"mxc://gua.global/AbCdEf","w":1536},"v":1}"#)
    }

    /// Synapse refuses an event holding a float, or an integer beyond 2^53 - 1, in room versions 6 and later.
    func testEveryWrittenNumberIsACanonicalJSONInteger() throws {
        var photo = ChatBackground.Photo.mock
        photo.dim = 0.351_234
        photo.alignX = 0.123_456
        photo.alignY = 1

        for background in [ChatBackground.none, .preset(.aurora), .photo(.mock), .photo(photo)] {
            let numbers = numberTokens(in: background.contentJSON)
            XCTAssertEqual(numbers.isEmpty, background.isNone)
            for number in numbers {
                let integer = try XCTUnwrap(Int64(number), "\(number) in \(background.contentJSON)")
                XCTAssertLessThanOrEqual(abs(integer), 9_007_199_254_740_991)
            }
        }
    }

    func testPhotoWithoutBlurhashOmitsIt() throws {
        var photo = ChatBackground.Photo.mock
        photo.blurhash = nil
        let written = try XCTUnwrap(jsonObject(ChatBackground.photo(photo).contentJSON)["photo"] as? [String: Any])
        XCTAssertNil(written["blurhash"])
    }

    func testEveryPresetRoundTrips() {
        for preset in ChatBackgroundPreset.allCases {
            XCTAssertEqual(ChatBackground(contentJSON: ChatBackground.preset(preset).contentJSON), .preset(preset))
        }
    }

    func testPresetIDsMatchTheSpec() {
        XCTAssertEqual(ChatBackgroundPreset.allCases.map(\.id),
                       ["aurora", "mint", "sky", "sand", "blush", "lavender", "graphite", "sunset", "ocean", "night"])
        XCTAssertNil(ChatBackgroundPreset(id: "Aurora"))
        XCTAssertNil(ChatBackgroundPreset(id: ""))
        XCTAssertNil(ChatBackgroundPreset(id: String(repeating: "a", count: 33)))
        XCTAssertNil(ChatBackgroundPreset(id: "rainbow"))
    }

    func testTimelineEventReadsContentFromTheEventJSON() {
        let changed = ChatBackgroundTimelineEvent(eventID: "$1",
                                                  timestamp: 5,
                                                  eventJSON: #"{"type":"global.gua.room.background","state_key":"","content":{"v":1,"kind":"preset","preset":"sky"}}"#)
        XCTAssertEqual(ChatBackground(contentJSON: changed.contentJSON), .preset(.sky))
        XCTAssertFalse(changed.isRemoval)

        let removed = ChatBackgroundTimelineEvent(eventID: "$2", timestamp: 6, eventJSON: #"{"type":"global.gua.room.background","content":{}}"#)
        XCTAssertTrue(removed.isRemoval)

        let unreadable = ChatBackgroundTimelineEvent(eventID: "$3", timestamp: 7, eventJSON: nil)
        XCTAssertNil(unreadable.contentJSON)
        XCTAssertFalse(unreadable.isRemoval)
    }

    private func jsonObject(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func background(fromExpected expected: [String: Any]) throws -> ChatBackground {
        switch expected["kind"] as? String {
        case "none":
            return .none
        case "preset":
            return try .preset(XCTUnwrap(ChatBackgroundPreset(rawValue: XCTUnwrap(expected["preset"] as? String))))
        case "photo":
            let photo = try XCTUnwrap(expected["photo"] as? [String: Any])
            let align = try XCTUnwrap(photo["align"] as? [String: Any])
            return try .photo(.init(url: XCTUnwrap(photo["url"] as? String),
                                    mimetype: XCTUnwrap(photo["mimetype"] as? String),
                                    width: XCTUnwrap(photo["w"] as? Int),
                                    height: XCTUnwrap(photo["h"] as? Int),
                                    size: XCTUnwrap(photo["size"] as? Int),
                                    blurhash: photo["blurhash"] as? String,
                                    dim: Double(XCTUnwrap(photo["dim"] as? Int)) / ChatBackground.Photo.dimScale,
                                    alignX: Double(XCTUnwrap(align["x"] as? Int)) / ChatBackground.Photo.alignScale,
                                    alignY: Double(XCTUnwrap(align["y"] as? Int)) / ChatBackground.Photo.alignScale))
        default:
            XCTFail("Unknown expected kind")
            return .none
        }
    }

    private func numberTokens(in json: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var isInString = false
        var isEscaped = false

        for character in json {
            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInString = false
                }
            } else if character == "\"" {
                isInString = true
            } else if (current.isEmpty ? "-0123456789" : "+-.eE0123456789").contains(character) {
                current.append(character)
                continue
            }
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        return tokens
    }

    private func rawValues(forKey key: String, in text: String) -> [String] {
        let characters = Array(text)
        let marker = Array("\"\(key)\":")
        var values: [String] = []
        var index = 0

        while index + marker.count <= characters.count {
            guard Array(characters[index..<index + marker.count]) == marker else {
                index += 1
                continue
            }
            var start = index + marker.count
            while characters[start].isWhitespace {
                start += 1
            }
            var depth = 0
            var isInString = false
            var end = start
            repeat {
                let character = characters[end]
                if isInString {
                    if character == "\\" {
                        end += 1
                    } else if character == "\"" {
                        isInString = false
                    }
                } else if character == "\"" {
                    isInString = true
                } else if character == "{" || character == "[" {
                    depth += 1
                } else if character == "}" || character == "]" {
                    depth -= 1
                }
                end += 1
            } while depth > 0
            values.append(String(characters[start..<end]))
            index = end
        }
        return values
    }
}
