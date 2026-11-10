//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

final class ChatThemePrecedenceTests {
    @Test
    func sharedFixtures() throws {
        let url = try #require(Bundle(for: Self.self).url(forResource: "chat-theme-precedence-fixtures.json", withExtension: nil))
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try #require(root["cases"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        
        for fixture in cases {
            let name = try #require(fixture["name"] as? String)
            let effective = try ChatTheme.effective(chatTheme: theme(fixture["chatTheme"]),
                                                    defaultTheme: theme(fixture["defaultTheme"]),
                                                    roomIsPrivate: #require(fixture["roomIsPrivate"] as? Bool),
                                                    mediaShown: #require(fixture["mediaShown"] as? Bool))
            let expected = try ChatThemeCodecTests.theme(fromExpected: #require(fixture["expected"] as? [String: Any]))
            #expect(effective == expected, "\(name)")
        }
    }
    
    @Test
    func onlyAChatPhotoIsHidden() {
        let photo = ChatTheme(wallpaper: .photo(.mock), bubble: .pink)
        let preset = ChatTheme(wallpaper: .preset(.night), bubble: .purple)
        let bubbleOnly = ChatTheme(wallpaper: .none, bubble: .yellow)
        let defaultTheme = ChatTheme(wallpaper: .preset(.aurora), bubble: .green)
        
        for (roomIsPrivate, mediaShown) in [(false, true), (true, false), (true, true)] {
            #expect(ChatTheme.effective(chatTheme: photo, defaultTheme: defaultTheme, roomIsPrivate: roomIsPrivate, mediaShown: mediaShown) == photo)
        }
        #expect(ChatTheme.effective(chatTheme: photo, defaultTheme: defaultTheme, roomIsPrivate: false, mediaShown: false) == defaultTheme)
        #expect(ChatTheme.effective(chatTheme: preset, defaultTheme: defaultTheme, roomIsPrivate: false, mediaShown: false) == preset)
        #expect(ChatTheme.effective(chatTheme: bubbleOnly, defaultTheme: defaultTheme, roomIsPrivate: false, mediaShown: false) == bubbleOnly)
    }
    
    private func theme(_ object: Any?) throws -> ChatTheme {
        let content = try #require(object as? [String: Any])
        return ChatTheme(contentJSON: ChatBackground.sortedJSON(content))
    }
}
