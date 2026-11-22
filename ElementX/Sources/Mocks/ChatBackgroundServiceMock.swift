//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation

struct ChatBackgroundServiceMockConfiguration {
    var theme = ChatTheme.stock
    var defaultTheme = ChatTheme.stock
}

extension ChatBackgroundServiceMock {
    convenience init(_ configuration: ChatBackgroundServiceMockConfiguration) {
        self.init()

        let subject = CurrentValueSubject<ChatTheme, Never>(configuration.theme)
        themePublisherRoomIDReturnValue = subject.asCurrentValuePublisher()
        setRoomProxyClosure = { theme, _ in
            subject.send(theme)
            return .success(())
        }

        let defaultSubject = CurrentValueSubject<ChatTheme, Never>(configuration.defaultTheme)
        underlyingDefaultThemePublisher = defaultSubject.asCurrentValuePublisher()
        setDefaultThemeClosure = { theme in
            defaultSubject.send(theme)
            return .success(())
        }
    }
}

extension ChatBackground.Photo {
    static var mock: ChatBackground.Photo {
        .init(url: URL.mockMXCImage.absoluteString,
              mimetype: "image/jpeg",
              width: 2708,
              height: 2028,
              size: 412_337,
              blurhash: "LEHV6nWB2yk8pyo0adR*.7kCMdnj")
    }
}
