//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import XCTest

final class ChatThemePrecedenceTests: XCTestCase {
    func testSharedFixtures() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "chat-theme-precedence-fixtures.json", withExtension: nil))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)

        for fixture in cases {
            let name = try XCTUnwrap(fixture["name"] as? String)
            let effective = try ChatTheme.effective(chatTheme: theme(fixture["chatTheme"]),
                                                    defaultTheme: theme(fixture["defaultTheme"]),
                                                    roomIsPrivate: XCTUnwrap(fixture["roomIsPrivate"] as? Bool),
                                                    mediaShown: XCTUnwrap(fixture["mediaShown"] as? Bool))
            let expected = try ChatThemeCodecTests.theme(fromExpected: XCTUnwrap(fixture["expected"] as? [String: Any]))
            XCTAssertEqual(effective, expected, name)
        }
    }

    func testOnlyAChatPhotoIsHidden() {
        let photo = ChatTheme(wallpaper: .photo(.mock), bubble: .pink)
        let preset = ChatTheme(wallpaper: .preset(.night), bubble: .purple)
        let bubbleOnly = ChatTheme(wallpaper: .none, bubble: .yellow)
        let defaultTheme = ChatTheme(wallpaper: .preset(.aurora), bubble: .green)

        for (roomIsPrivate, mediaShown) in [(false, true), (true, false), (true, true)] {
            XCTAssertEqual(ChatTheme.effective(chatTheme: photo, defaultTheme: defaultTheme, roomIsPrivate: roomIsPrivate, mediaShown: mediaShown), photo)
        }
        XCTAssertEqual(ChatTheme.effective(chatTheme: photo, defaultTheme: defaultTheme, roomIsPrivate: false, mediaShown: false), defaultTheme)
        XCTAssertEqual(ChatTheme.effective(chatTheme: preset, defaultTheme: defaultTheme, roomIsPrivate: false, mediaShown: false), preset)
        XCTAssertEqual(ChatTheme.effective(chatTheme: bubbleOnly, defaultTheme: defaultTheme, roomIsPrivate: false, mediaShown: false), bubbleOnly)
    }

    private func theme(_ object: Any?) throws -> ChatTheme {
        let content = try XCTUnwrap(object as? [String: Any])
        return ChatTheme(contentJSON: ChatBackground.sortedJSON(content))
    }
}
