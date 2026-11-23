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
            #expect(!ChatTheme(wallpaper: wallpaper).contentJSON.contains("bubble"))
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
    func everyArtworkAndBubblePairRoundTrips() {
        for artwork in ChatArtwork.allCases {
            for bubble in ChatBubbleColor.allCases {
                for bubbleDark in [nil] + ChatBubbleColor.allCases.map(Optional.some) {
                    let theme = ChatTheme(wallpaper: .art(artwork), bubble: bubble, bubbleDark: bubbleDark)
                    #expect(ChatTheme(contentJSON: theme.contentJSON) == theme)
                }
            }
        }
    }
    
    @Test
    func artworkIsWrittenWithItsFallback() throws {
        for artwork in ChatArtwork.allCases {
            let written = try jsonObject(ChatTheme(wallpaper: .art(artwork)).contentJSON)
            #expect(written as NSDictionary == ["art": artwork.id, "fallback_preset": artwork.fallbackPreset.id, "kind": "art", "v": 1] as NSDictionary)
        }
    }
    
    @Test
    func bubblePairKeepsADarkBubbleOnlyWhenItDiffers() {
        #expect(ChatBubblePair(.purple, dark: .pink).bubbleDark == .pink)
        #expect(ChatBubblePair(.purple, dark: .purple).bubbleDark == nil)
        #expect(ChatBubblePair(.purple, dark: .standard).bubbleDark == nil)
        #expect(ChatBubblePair(.standard, dark: .pink).bubbleDark == nil)
        #expect(ChatBubblePair(.purple, dark: .purple) == ChatBubblePair(.purple))
        #expect(ChatTheme(wallpaper: .none, bubble: .standard, bubbleDark: .pink).isStock)
    }
    
    @Test
    func bubblePairShowsAndNamesOneBubblePerAppearance() {
        let pair = ChatArtwork.glassDrops.bubbles
        #expect(pair.shown(in: .light) == .purple)
        #expect(pair.shown(in: .dark) == .pink)
        #expect(pair.name(in: .light) == UntranslatedL10n.guaChatThemeBubblePurple)
        #expect(pair.name(in: .dark) == UntranslatedL10n.guaChatThemeBubblePink)
        #expect(ChatBubblePair(.teal).name(in: .dark) == UntranslatedL10n.guaChatThemeBubbleTeal)
    }
    
    @Test
    func artworkIDsMatchTheSpec() {
        #expect(ChatArtwork.allCases.map(\.id) == ["glass-drops", "glass-drops-blue", "molten-pearl", "silk", "ipe", "rain-on-glass", "pantanal", "currents-live",
                                                   "boreal", "lagoon", "sea-sparks", "tropic-dusk",
                                                   "dune-lagoons", "palm-coast", "river-bends", "highland-mist", "glacier-lake", "canola-sky", "harbour-fog", "canyon-glow", "polar-ice", "moon-tide",
                                                   "photo-lencois-lagoon", "photo-lencois-dunes", "photo-gruta-azul", "photo-ipe", "photo-araucaria", "photo-maned-wolf",
                                                   "photo-maned-wolf-standing", "photo-yukon-trail", "photo-yukon-sun", "photo-yukon-forest", "photo-yukon-sled", "photo-yukon-sled-2",
                                                   "photo-peyto-lake", "photo-lone-canoe", "photo-jasper-aurora", "photo-nunavik-aurora", "photo-lac-delage", "photo-quebec-ice",
                                                   "photo-quebec-leaves",
                                                   "currents", "azulejo", "calcadao", "knit", "doodles-brasil", "doodles-canada",
                                                   "paper", "paper-cut"])
        #expect(ChatArtwork.allCases.filter(\.isLive) == ChatArtwork.artworks(in: .live))
        
        let originalPresets: Set<ChatBackgroundPreset> = [.aurora, .mint, .sky, .sand, .blush, .lavender, .graphite, .sunset, .ocean, .night]
        #expect(ChatArtwork.allCases.allSatisfy { originalPresets.contains($0.fallbackPreset) })
        
        let reserved: Set = ["rainbow", "pattern", "video", "Blue"]
        #expect(reserved.isDisjoint(with: ChatArtwork.allCases.map(\.id)))
    }
    
    @Test
    func photoCreditsMatchTheSpec() {
        #expect(ChatArtwork.Licence.cc0.name == "CC0 1.0")
        #expect(ChatArtwork.Licence.cc0.deedURL.absoluteString == "https://creativecommons.org/publicdomain/zero/1.0/")
        #expect(ChatArtwork.Licence.ccBy4.name == "CC BY 4.0")
        #expect(ChatArtwork.Licence.ccBy4.deedURL.absoluteString == "https://creativecommons.org/licenses/by/4.0/")
        
        for artwork in ChatArtwork.allCases {
            #expect((artwork.credit != nil) == artwork.isPhoto, "\(artwork.id)")
        }
        
        let photos = ChatArtwork.artworks(in: .photos)
        #expect(photos.allSatisfy { $0.id.hasPrefix("photo-") && !$0.isLive })
        #expect(photos.allSatisfy { $0.fileNames.light == "\($0.id).webp" && $0.fileNames.dark == "\($0.id).webp" })
        
        let ownPhotos: [ChatArtwork] = [.photoYukonTrail, .photoYukonSun, .photoYukonForest, .photoYukonSled, .photoYukonSled2]
        #expect(photos.filter { $0.credit?.licence == .ccBy4 } == ownPhotos)
        #expect(photos.filter { $0.credit?.sourceURL == nil } == ownPhotos)
    }
    
    @Test
    func photosGetTheScrimOfAUsersPhotoAtItsDefaultDim() {
        #expect(ChatBackground.Photo.defaultDim == 0.35)
        for artwork in ChatArtwork.allCases {
            #expect(artwork.photoDim == (artwork.isPhoto ? ChatBackground.Photo.defaultDim : nil), "\(artwork.id)")
        }
    }
    
    @Test
    func presetIDsMatchTheSpec() {
        #expect(ChatBackgroundPreset.allCases.map(\.id) == ["aurora", "mint", "sky", "sand", "blush", "lavender", "graphite", "sunset", "ocean", "night", "dawn", "forest", "dusk", "citrus"])
        #expect(ChatBackgroundPreset.solids == [.mint, .sky, .sand, .blush, .lavender, .graphite])
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
            section.themes.map { theme in
                let bubbles = [theme.bubble.id, theme.bubbleDark?.id].compactMap(\.self).joined(separator: "/")
                return "\(Self.id(of: theme.wallpaper))+\(bubbles)"
            }
        }
        #expect(ChatThemeGallerySection.all.map(\.id) == [.featured, .live, .nature, .photos, .patterns, .minimal, .gradients])
        #expect(sections == [["silk+teal", "glacier-lake+teal", "glass-drops+purple/pink", "currents+purple", "palm-coast+orange/blue", "ipe+pink/yellow", "azulejo+blue", "paper+green"],
                             ["glass-drops+purple/pink", "glass-drops-blue+teal", "molten-pearl+purple/blue", "silk+teal",
                              "ipe+pink/yellow", "rain-on-glass+green/blue", "pantanal+green", "currents-live+purple",
                              "boreal+blue/green", "lagoon+blue/teal", "sea-sparks+blue/teal", "tropic-dusk+pink/orange"],
                             ["dune-lagoons+teal/purple", "palm-coast+orange/blue", "river-bends+teal", "highland-mist+blue/green", "glacier-lake+teal", "canola-sky+green/orange",
                              "harbour-fog+blue", "canyon-glow+blue/purple", "polar-ice+blue/purple", "moon-tide+blue"],
                             ["photo-lencois-lagoon+teal/purple", "photo-lencois-dunes+blue/purple", "photo-gruta-azul+teal/blue", "photo-ipe+blue/orange",
                              "photo-araucaria+green/teal", "photo-maned-wolf+blue/purple", "photo-maned-wolf-standing+blue/purple", "photo-yukon-trail+blue/teal",
                              "photo-yukon-sun+orange/blue", "photo-yukon-forest+green/teal", "photo-yukon-sled+purple/blue", "photo-yukon-sled-2+teal/purple",
                              "photo-peyto-lake+teal/blue", "photo-lone-canoe+orange/purple", "photo-jasper-aurora+green/teal", "photo-nunavik-aurora+purple/pink",
                              "photo-lac-delage+blue", "photo-quebec-ice+green/teal", "photo-quebec-leaves+teal/graphite"],
                             ["currents+purple", "azulejo+blue", "calcadao+teal", "knit+blue", "doodles-brasil+green", "doodles-canada+blue"],
                             ["paper+green", "paper-cut+teal/orange", "mint+green", "sky+blue", "sand+orange", "blush+pink", "lavender+purple", "graphite+graphite"],
                             ["aurora+teal", "sunset+orange", "ocean+blue", "night+purple", "dawn+pink", "forest+teal", "dusk+purple", "citrus+green"]])
    }
    
    @Test
    func wallpaperPickerMatchesTheSpec() {
        #expect(ChatWallpaperGallerySection.all.map(\.id) == [.live, .nature, .photos, .patterns, .minimal, .gradients])
        #expect(ChatWallpaperGallerySection.all.map { $0.wallpapers.map(Self.id) } == [ChatArtwork.artworks(in: .live).map(\.id),
                                                                                       ChatArtwork.artworks(in: .nature).map(\.id),
                                                                                       ChatArtwork.artworks(in: .photos).map(\.id),
                                                                                       ChatArtwork.artworks(in: .patterns).map(\.id),
                                                                                       ["paper", "paper-cut", "mint", "sky", "sand", "blush", "lavender", "graphite"],
                                                                                       ["aurora", "sunset", "ocean", "night", "dawn", "forest", "dusk", "citrus"]])
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
    
    private static func id(of wallpaper: ChatBackground) -> String {
        switch wallpaper {
        case .preset(let preset): preset.id
        case .art(let artwork): artwork.id
        case .none, .photo: "?"
        }
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
        let bubbleDark = try (expected["bubble_dark"] as? String).map { try #require(ChatBubbleColor(rawValue: $0)) }
        return try ChatTheme(wallpaper: wallpaper(fromExpected: expected), bubble: bubble, bubbleDark: bubbleDark)
    }
    
    private static func wallpaper(fromExpected expected: [String: Any]) throws -> ChatBackground {
        switch expected["kind"] as? String {
        case "none":
            return .none
        case "preset":
            let preset = try #require(expected["preset"] as? String)
            return try .preset(#require(ChatBackgroundPreset(rawValue: preset)))
        case "art":
            let artwork = try #require(expected["art"] as? String)
            return try .art(#require(ChatArtwork(rawValue: artwork)))
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
