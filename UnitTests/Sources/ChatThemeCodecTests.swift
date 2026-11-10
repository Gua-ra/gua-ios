//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import SwiftUI
import Testing

final class ChatThemeCodecTests {
    @Test
    func sharedFixtures() throws {
        let url = try #require(Bundle(for: Self.self).url(forResource: "chat-background-fixtures.json", withExtension: nil))
        let text = try String(contentsOf: url, encoding: .utf8)
        let root = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let cases = try #require(root["cases"] as? [[String: Any]])
        // The raw text keeps numbers such as 1.0 exactly as written, which reserialising would not.
        let contents = rawValues(forKey: "content", in: text)
        
        #expect(!cases.isEmpty)
        #expect(cases.count == contents.count)
        
        for (fixture, content) in zip(cases, contents) {
            let name = try #require(fixture["name"] as? String)
            let expected = try Self.theme(fromExpected: #require(fixture["expected"] as? [String: Any]))
            #expect(ChatTheme(contentJSON: content) == expected, "\(name)")
        }
        
        let encodeCases = try #require(root["encode_cases"] as? [[String: Any]])
        #expect(!encodeCases.isEmpty)
        
        for fixture in encodeCases {
            let name = try #require(fixture["name"] as? String)
            let theme = try Self.theme(fromExpected: #require(fixture["theme"] as? [String: Any]))
            #expect(theme.contentJSON == fixture["expected"] as? String, "\(name)")
        }
    }
    
    @Test
    func unreadableContentIsNoTheme() {
        #expect(ChatTheme(contentJSON: nil) == .stock)
        #expect(ChatTheme(contentJSON: "") == .stock)
        #expect(ChatTheme(contentJSON: "{not json") == .stock)
        #expect(ChatTheme(contentJSON: "\"aurora\"") == .stock)
    }
    
    @Test
    func presetIsWrittenInTheSharedFormat() {
        #expect(ChatTheme(wallpaper: .preset(.aurora)).contentJSON == #"{"kind":"preset","preset":"aurora","v":1}"#)
        #expect(ChatTheme(wallpaper: .preset(.aurora), bubble: .green).contentJSON == #"{"bubble":"green","kind":"preset","preset":"aurora","v":1}"#)
    }
    
    @Test
    func bubbleWithoutAWallpaperIsWrittenAsKindNone() {
        #expect(ChatTheme(wallpaper: .none, bubble: .blue).contentJSON == #"{"bubble":"blue","kind":"none","v":1}"#)
    }
    
    @Test
    func noThemeIsWrittenAsEmptyContent() {
        #expect(ChatTheme.stock.contentJSON == "{}")
        #expect(ChatTheme(wallpaper: .none, bubble: .standard).contentJSON == "{}")
    }
    
    @Test
    func standardIsNeverWritten() {
        for wallpaper in [ChatBackground.preset(.ocean), .photo(.mock)] {
            #expect(!(ChatTheme(wallpaper: wallpaper).contentJSON.contains("bubble")))
        }
    }
    
    @Test
    func photoIsWrittenRoundedAndReadsBack() throws {
        let photo = ChatBackground.Photo(url: "mxc://gua.global/AbCdEf",
                                         mimetype: "image/jpeg",
                                         width: 1536,
                                         height: 2048,
                                         size: 412_337,
                                         blurhash: "LKO2?U%2Tw=w]~RBVZRi};RPxuwH",
                                         dim: 0.351_234,
                                         alignX: 0.123_456,
                                         alignY: 1)
        let theme = ChatTheme(wallpaper: .photo(photo), bubble: .orange)
        let written = try #require(jsonObject(theme.contentJSON)["photo"] as? [String: Any])
        #expect(written["dim"] as? Int == 35)
        #expect(written["align"] as? NSDictionary == ["x": 123, "y": 1000] as NSDictionary)
        
        var rounded = photo
        rounded.dim = 0.35
        rounded.alignX = 0.123
        #expect(ChatTheme(contentJSON: theme.contentJSON) == ChatTheme(wallpaper: .photo(rounded), bubble: .orange))
    }
    
    @Test
    func photoIsWrittenInTheSharedFormat() {
        let photo = ChatBackground.Photo(url: "mxc://gua.global/AbCdEf",
                                         mimetype: "image/jpeg",
                                         width: 1536,
                                         height: 2048,
                                         size: 412_337,
                                         blurhash: "LKO2?U%2Tw=w]~RBVZRi};RPxuwH")
        #expect(ChatTheme(wallpaper: .photo(photo)).contentJSON == #"{"kind":"photo","photo":{"align":{"x":500,"y":500},"blurhash":"LKO2?U%2Tw=w]~RBVZRi};RPxuwH","dim":35,"h":2048,"mimetype":"image/jpeg","size":412337,"url":"mxc://gua.global/AbCdEf","w":1536},"v":1}"#)
    }
    
    @Test
    func photoWithoutBlurhashOmitsIt() throws {
        var photo = ChatBackground.Photo.mock
        photo.blurhash = nil
        let written = try #require(jsonObject(ChatTheme(wallpaper: .photo(photo)).contentJSON)["photo"] as? [String: Any])
        #expect(written["blurhash"] == nil)
    }
    
    @Test
    func everyPresetAndBubbleRoundTrips() {
        for preset in ChatBackgroundPreset.allCases {
            for bubble in ChatBubbleColor.allCases {
                let theme = ChatTheme(wallpaper: .preset(preset), bubble: bubble)
                #expect(ChatTheme(contentJSON: theme.contentJSON) == theme)
            }
        }
    }
    
    @Test
    func presetIDsMatchTheSpec() {
        #expect(ChatBackgroundPreset.allCases.map(\.id) == ["aurora", "mint", "sky", "sand", "blush", "lavender", "graphite", "sunset", "ocean", "night", "dawn", "forest", "dusk", "citrus"])
        #expect(ChatBackgroundPreset.colours == [.mint, .sky, .sand, .blush, .lavender, .graphite])
        #expect(ChatBackgroundPreset.gradients == [.aurora, .sunset, .ocean, .night, .dawn, .forest, .dusk, .citrus])
    }
    
    @Test
    func newPresetColoursMatchTheSpec() {
        #expect(stops(ChatBackgroundPreset.dawn.fill(for: .light)) == LinearStops(start: .top, colors: [0xF6D9BF, 0xC9DDF0]))
        #expect(stops(ChatBackgroundPreset.dawn.fill(for: .dark)) == LinearStops(start: .top, colors: [0x1E140C, 0x0B1626]))
        #expect(stops(ChatBackgroundPreset.forest.fill(for: .light)) == LinearStops(start: .topLeading, colors: [0xB9D8B0, 0x9CC7B4]))
        #expect(stops(ChatBackgroundPreset.forest.fill(for: .dark)) == LinearStops(start: .topLeading, colors: [0x07140A, 0x0A1A14]))
        #expect(stops(ChatBackgroundPreset.dusk.fill(for: .light)) == LinearStops(start: .top, colors: [0xD9C2EA, 0xF1C9B8]))
        #expect(stops(ChatBackgroundPreset.dusk.fill(for: .dark)) == LinearStops(start: .top, colors: [0x140C22, 0x21120C]))
        #expect(stops(ChatBackgroundPreset.citrus.fill(for: .light)) == LinearStops(start: .topLeading, colors: [0xF2E6A8, 0xBFE3B4]))
        #expect(stops(ChatBackgroundPreset.citrus.fill(for: .dark)) == LinearStops(start: .topLeading, colors: [0x1A1606, 0x0B1A0C]))
    }
    
    @Test
    func bubblePaletteMatchesTheSpec() {
        #expect(ChatBubbleColor.allCases.map(\.id) == ["standard", "green", "teal", "blue", "purple", "pink", "orange", "yellow", "graphite"])
        #expect(ChatBubbleColor.standard.hex == nil)
        let palette = ChatBubbleColor.allCases.compactMap { $0.hex.map { [$0.light, $0.dark] } }
        #expect(palette == [[0xD9F4DD, 0x173826],
                            [0xD3F1EC, 0x123A38],
                            [0xDCE8FA, 0x18304F],
                            [0xE8E0F8, 0x30264D],
                            [0xF9DDE8, 0x4A1F36],
                            [0xFBE4D0, 0x4A2B14],
                            [0xF7F0CC, 0x3F3612],
                            [0xE1E4E9, 0x2F333A]])
    }
    
    @Test
    func galleryMatchesTheSpec() {
        let sections = ChatThemeGallerySection.all.map { section in
            section.themes.map { theme -> String in
                guard case .preset(let preset) = theme.wallpaper else { return "?" }
                return "\(preset.id)+\(theme.bubble.id)"
            }
        }
        #expect(ChatThemeGallerySection.all.map(\.id) == [.featured, .colours, .gradients])
        #expect(sections == [["aurora+green", "ocean+teal", "sunset+pink", "night+purple", "dawn+blue", "forest+green", "dusk+orange", "citrus+yellow"],
                             ["mint+green", "sky+blue", "sand+orange", "blush+pink", "lavender+purple", "graphite+graphite"],
                             ["aurora+teal", "sunset+orange", "ocean+blue", "night+purple", "dawn+pink", "forest+teal", "dusk+purple", "citrus+green"]])
    }
    
    @Test
    func timelineEventReadsContentFromTheEventJSON() {
        let changed = ChatBackgroundTimelineEvent(eventID: "$1",
                                                  timestamp: 5,
                                                  eventJSON: #"{"type":"global.gua.room.background","state_key":"","content":{"v":1,"kind":"preset","preset":"sky"}}"#)
        #expect(ChatTheme(contentJSON: changed.contentJSON) == ChatTheme(wallpaper: .preset(.sky)))
        #expect(!changed.isRemoval)
        
        let removed = ChatBackgroundTimelineEvent(eventID: "$2", timestamp: 6, eventJSON: #"{"type":"global.gua.room.background","content":{}}"#)
        #expect(removed.isRemoval)
        
        let unreadable = ChatBackgroundTimelineEvent(eventID: "$3", timestamp: 7, eventJSON: nil)
        #expect(unreadable.contentJSON == nil)
        #expect(!unreadable.isRemoval)
    }
    
    private func jsonObject(_ json: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }
    
    private struct LinearStops: Equatable {
        let start: UnitPoint
        let colors: [UInt32]
    }
    
    private func stops(_ fill: ChatBackgroundFill) -> LinearStops? {
        guard case .linear(let start, _, let stops) = fill, stops.map(\.location) == [0, 1] else { return nil }
        return LinearStops(start: start, colors: stops.map(\.color))
    }
    
    static func theme(fromExpected expected: [String: Any]) throws -> ChatTheme {
        let bubble = try #require(ChatBubbleColor(rawValue: expected["bubble"] as? String ?? ChatBubbleColor.standard.rawValue))
        return try ChatTheme(wallpaper: wallpaper(fromExpected: expected), bubble: bubble)
    }
    
    private static func wallpaper(fromExpected expected: [String: Any]) throws -> ChatBackground {
        switch expected["kind"] as? String {
        case "none":
            return .none
        case "preset":
            let preset = try #require(expected["preset"] as? String)
            return try .preset(#require(ChatBackgroundPreset(rawValue: preset)))
        case "photo":
            let photo = try #require(expected["photo"] as? [String: Any])
            let align = try #require(photo["align"] as? [String: Any])
            return try .photo(.init(url: #require(photo["url"] as? String),
                                    mimetype: #require(photo["mimetype"] as? String),
                                    width: #require(photo["w"] as? Int),
                                    height: #require(photo["h"] as? Int),
                                    size: #require(photo["size"] as? Int),
                                    blurhash: photo["blurhash"] as? String,
                                    dim: Double(#require(photo["dim"] as? Int)) / ChatBackground.Photo.dimScale,
                                    alignX: Double(#require(align["x"] as? Int)) / ChatBackground.Photo.alignScale,
                                    alignY: Double(#require(align["y"] as? Int)) / ChatBackground.Photo.alignScale))
        default:
            Issue.record("Unknown expected kind")
            return .none
        }
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
