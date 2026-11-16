//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import CryptoKit
@testable import ElementX
import Foundation
import ImageIO
import Testing

final class ChatArtworkManifestTests {
    @Test
    func catalogMatchesTheManifest() throws {
        let entries = try Self.artworkEntries()
        #expect(entries.map { $0["id"] as? String } == ChatArtwork.allCases.map(\.id))
        
        for (artwork, entry) in zip(ChatArtwork.allCases, entries) {
            #expect(entry["section"] as? String == artwork.section.rawValue, "\(artwork.id)")
            #expect(entry["live"] as? Bool == artwork.isLive, "\(artwork.id)")
            #expect(entry["fallback_preset"] as? String == artwork.fallbackPreset.id, "\(artwork.id)")
            #expect(entry["files"] as? [String: String] == ["light": artwork.fileNames.light, "dark": artwork.fileNames.dark], "\(artwork.id)")
            
            let anchor = try #require(entry["anchor"] as? [String: Double])
            #expect(anchor == ["x": Double(artwork.anchor.x), "y": Double(artwork.anchor.y)], "\(artwork.id)")
            
            let bubble = try #require(entry["bubble"] as? [String: String])
            #expect(bubble["light"] == artwork.bubbles.bubble.id, "\(artwork.id)")
            #expect(bubble["dark"] == (artwork.bubbles.bubbleDark ?? artwork.bubbles.bubble).id, "\(artwork.id)")
        }
    }
    
    @Test
    func everyArtworkIsBundledAsListed() throws {
        let entries = try Self.artworkEntries()
        
        for (artwork, entry) in zip(ChatArtwork.allCases, entries) {
            let hashes = try #require(entry["sha256"] as? [String: String])
            #expect(Set(hashes.keys) == [artwork.fileNames.light, artwork.fileNames.dark], "\(artwork.id)")
            
            for (file, hash) in hashes {
                let url = try #require(ChatArtworkLoader.url(for: file), "\(file) is not in the app bundle")
                #expect(try Self.sha256(of: url) == hash, "\(file)")
                #expect(Self.pixelSize(of: url) == ChatArtwork.pixelSize, "\(file)")
            }
        }
    }
    
    @Test
    func grainTileIsBundledAsListed() throws {
        let noise = try #require(Self.manifest()["noise"] as? [String: Any])
        let file = try #require(noise["file"] as? String)
        let url = try #require(ChatArtworkLoader.url(for: file))
        
        #expect(try Self.sha256(of: url) == noise["sha256"] as? String)
        #expect(ChatArtworkLoader.grainTile?.width == noise["width"] as? Int)
        #expect(ChatArtworkLoader.grainTile?.height == noise["height"] as? Int)
    }
    
    @Test
    func artworksDecodeAtTheRequestedSize() async throws {
        let request = ChatArtworkLoader.request(for: .glacierLake, colorScheme: .dark, filling: CGSize(width: 84, height: 149), displayScale: 2)
        #expect(request.file == "glacier-lake-dark.webp")
        #expect(request.maxPixelSize == 512)
        
        let image = try #require(await ChatArtworkLoader.loadImage(for: request))
        #expect(max(image.size.width, image.size.height) == 512)
        
        let fullScreen = ChatArtworkLoader.request(for: .glacierLake, colorScheme: .light, filling: CGSize(width: 1366, height: 1024), displayScale: 2)
        #expect(fullScreen.maxPixelSize == Int(ChatArtwork.pixelSize.height))
    }
    
    private static func manifest() throws -> [String: Any] {
        let url = try #require(ChatArtworkLoader.url(for: "manifest.json"), "manifest.json is not in the app bundle")
        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    
    private static func artworkEntries() throws -> [[String: Any]] {
        try #require(manifest()["artworks"] as? [[String: Any]])
    }
    
    private static func sha256(of url: URL) throws -> String {
        try SHA256.hash(data: Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
    
    private static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return CGSize(width: width, height: height)
    }
}
