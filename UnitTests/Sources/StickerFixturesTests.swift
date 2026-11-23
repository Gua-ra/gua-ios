//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

@testable import ElementX
import Foundation
import Testing

/// Drives the codecs from the fixtures shared byte for byte with Android.
final class StickerFixturesTests {
    private static let sharedInfo: JSONValue = .object(["h": .int(256), "mimetype": .string("image/png"), "size": .int(120_034), "w": .int(256)])
    private static let generateStart: Int64 = 1_762_905_600_000
    
    private let fixtures: [String: JSONValue]
    
    init() throws {
        let url = try #require(Bundle(for: Self.self).url(forResource: "stickers-fixtures.json", withExtension: nil))
        fixtures = try #require(JSONValue(jsonString: String(contentsOf: url, encoding: .utf8))?.objectValue)
    }
    
    @Test
    func stickerContent() throws {
        let cases = try cases("stickerContent")
        
        for fixture in cases {
            let name = try string(fixture["name"])
            let input = try #require(fixture["input"]?.objectValue)
            let image = try StickerImage(url: string(input["url"]),
                                         body: string(input["body"]),
                                         mimetype: string(input["mimetype"]),
                                         pixelWidth: int(input["width"]),
                                         pixelHeight: int(input["height"]),
                                         size: int(input["size"]),
                                         isAnimated: input["isAnimated"]?.boolValue ?? false)
            let relation: StickerRelation? = if let root = input["threadRoot"]?.stringValue {
                try .thread(rootEventID: root, latestEventID: string(input["replyTo"]))
            } else {
                input["replyTo"]?.stringValue.map { .reply(eventID: $0) }
            }
            
            let content = StickerMessageContent(image: image, relation: relation).json
            
            #expect(JSONValue(jsonString: content.jsonString) == fixture["expected"], "\(name)")
        }
    }
    
    @Test
    func libraryDecoding() throws {
        let section = try #require(fixtures["library"]?.objectValue)
        let cases = try #require(section["decode"]?.arrayValue).compactMap(\.objectValue)
        #expect(!cases.isEmpty)
        
        for fixture in cases {
            let name = try string(fixture["name"])
            let decoded = try StickerLibrary(contentJSON: #require(fixture["input"]).jsonString)
            
            #expect(Self.normalised(decoded) == fixture["expected"], "\(name)")
        }
    }
    
    @Test
    func libraryOperations() throws {
        let section = try #require(fixtures["library"]?.objectValue)
        let cases = try #require(section["operations"]?.arrayValue).compactMap(\.objectValue)
        #expect(!cases.isEmpty)
        
        for fixture in cases {
            let name = try string(fixture["name"])
            var library = try StickerLibrary(contentJSON: Self.start(#require(fixture["start"])).jsonString)
            let operation = try #require(fixture["op"]?.objectValue)
            
            do {
                try apply(operation, to: &library)
            } catch {
                #expect(fixture["expectedError"]?.stringValue == "limitReached" && error == .limitReached, "\(name)")
                continue
            }
            #expect(fixture["expectedError"] == nil, "\(name)")
            
            if let count = fixture["expectedFavouritesCount"]?.intValue {
                #expect(library.favourites.count == count, "\(name)")
                #expect(library.favourites.first?.json == fixture["expectedFirstFavourite"], "\(name)")
                #expect(library.favourites.last?.json == fixture["expectedLastFavourite"], "\(name)")
            } else {
                #expect(JSONValue(jsonString: library.contentJSON) == fixture["expected"], "\(name)")
            }
        }
    }
    
    @Test
    func shortcodes() throws {
        let cases = try cases("shortcodes")
        
        for fixture in cases {
            let existing = try Set(#require(fixture["existing"]?.arrayValue).compactMap(\.stringValue))
            let shortcode = try StickerLibrary.shortcode(now: #require(fixture["now"]?.intValue), existing: existing)
            
            #expect(try shortcode == string(fixture["expected"]))
        }
    }
    
    @Test
    func packs() throws {
        let cases = try cases("packs")
        
        for fixture in cases {
            let name = try string(fixture["name"])
            let pack = try StickerPack(eventType: string(fixture["eventType"]),
                                       stateKey: string(fixture["stateKey"]),
                                       content: #require(fixture["content"]),
                                       roomName: string(fixture["roomName"]),
                                       roomAvatarURL: nil)
            let normalised: JSONValue = .object(["avatarUrl": pack.avatarURL.map(JSONValue.string) ?? .null,
                                                 "displayName": .string(pack.displayName),
                                                 "stickers": .array(pack.stickers.map(Self.normalised))])
            
            #expect(normalised == fixture["expected"], "\(name)")
        }
    }
    
    @Test
    func packAvatarFallsBackToTheChat() {
        let pack = StickerPack(eventType: StickerPack.stableEventType,
                               stateKey: "",
                               content: .object(["images": .object([:])]),
                               roomName: "Family",
                               roomAvatarURL: "mxc://gua.global/room")
        
        #expect(pack.avatarURL == "mxc://gua.global/room")
    }
    
    @Test
    func gifRendition() throws {
        let cases = try cases("gifRendition")
        
        for fixture in cases {
            let name = try string(fixture["name"])
            let response: JSONValue = try .object(["data": .object(["data": .array([#require(fixture["item"])]), "has_next": .bool(false)])])
            let page = try KlipyGifProvider.page(from: Data(response.jsonString.utf8), page: 1).get()
            
            let choice = page.items.first?.sendChoice
            let normalised: JSONValue = choice.map { choice in
                .object(["body": .string(choice.body),
                         "height": .int(Int64(choice.animated.height)),
                         "rendition": .string(choice.rendition.rawValue),
                         "size": .int(Int64(choice.animated.size)),
                         "thumbnailUrl": .string(choice.still.url.absoluteString),
                         "url": .string(choice.animated.url.absoluteString),
                         "width": .int(Int64(choice.animated.width))])
            } ?? .null
            
            #expect(normalised == fixture["expected"], "\(name)")
        }
    }
    
    @Test
    func gifLibrary() throws {
        let cases = try cases("gifLibrary")
        
        for fixture in cases {
            let name = try string(fixture["name"])
            var favourites = try GifFavourites(contentJSON: #require(fixture["start"]).jsonString)
            let operation = try #require(fixture["op"]?.objectValue)
            let id = try string(operation["id"])
            
            switch try string(operation["type"]) {
            case "favourite":
                favourites.favourite(id: id, provider: KlipyGifProvider.providerID, limit: fixture["limit"]?.intValue.map(Int.init) ?? GifFavourites.maxFavourites)
            case "unfavourite":
                favourites.unfavourite(id: id, provider: KlipyGifProvider.providerID)
            default:
                Issue.record("Unknown operation in \(name)")
            }
            
            #expect(JSONValue(jsonString: favourites.contentJSON) == fixture["expected"], "\(name)")
        }
    }
    
    private func cases(_ key: String) throws -> [[String: JSONValue]] {
        let cases = try #require(fixtures[key]?.arrayValue).compactMap(\.objectValue)
        #expect(!cases.isEmpty)
        return cases
    }
    
    private func apply(_ operation: [String: JSONValue], to library: inout StickerLibrary) throws(StickerLibraryError) {
        switch operation["type"]?.stringValue {
        case "add":
            let image = StickerImage(url: operation["url"]?.stringValue ?? "",
                                     body: operation["body"]?.stringValue,
                                     info: operation["info"]?.objectValue.map(StickerImageInfo.init(fields:)))
            try library.add(image, now: operation["now"]?.intValue ?? 0)
        case "favourite":
            if let image = operation["image"].flatMap(StickerImage.init(json:)) {
                library.favourite(image)
            }
        case "unfavourite":
            library.unfavourite(url: operation["url"]?.stringValue ?? "")
        case "delete":
            library.delete(shortcode: operation["shortcode"]?.stringValue ?? "")
        default:
            Issue.record("Unknown operation \(operation)")
        }
    }
    
    /// Expands the `generate` shorthand the fixtures' notes describe.
    private static func start(_ start: JSONValue) -> JSONValue {
        guard let generate = start.objectValue?["generate"]?.objectValue else { return start }
        let imageCount = generate["images"]?.intValue ?? 0
        let favouriteCount = generate["favourites"]?.intValue ?? 0
        
        var images = [String: JSONValue]()
        for index in 0..<imageCount {
            let added = generateStart + index
            images["s" + String(added, radix: 36)] = .object(["url": .string("mxc://gua.global/s\(index)"),
                                                              "body": .string("S\(index)"),
                                                              "info": sharedInfo,
                                                              StickerImage.addedKey: .int(added)])
        }
        let favourites: [JSONValue] = (0..<favouriteCount).map { index in
            .object(["url": .string("mxc://gua.global/f\(index)"), "body": .string("F\(index)"), "info": sharedInfo])
        }
        return .object(["v": .int(1), "images": .object(images), "favourites": .array(favourites)])
    }
    
    private static func normalised(_ library: StickerLibrary) -> JSONValue {
        .object(["favourites": .array(library.favourites.map(\.json)),
                 "images": .array(library.images.map { item in
                     .object(["added": item.image.added.map(JSONValue.int) ?? .null,
                              "body": item.image.body.map(JSONValue.string) ?? .null,
                              "info": item.image.info?.json ?? .null,
                              "shortcode": .string(item.shortcode),
                              "url": .string(item.image.url)])
                 })])
    }
    
    private static func normalised(_ item: StickerPackItem) -> JSONValue {
        .object(["body": item.image.body.map(JSONValue.string) ?? .null,
                 "info": item.image.info?.json ?? .null,
                 "shortcode": .string(item.shortcode),
                 "url": .string(item.image.url)])
    }
    
    private func string(_ value: JSONValue?, sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        try #require(value?.stringValue, sourceLocation: sourceLocation)
    }
    
    private func int(_ value: JSONValue?, sourceLocation: SourceLocation = #_sourceLocation) throws -> Int {
        try Int(#require(value?.intValue, sourceLocation: sourceLocation))
    }
}
