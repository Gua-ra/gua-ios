//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation

struct ChatBackgroundServiceMockConfiguration {
    var background: ChatBackground = .none
}

extension ChatBackgroundServiceMock {
    convenience init(_ configuration: ChatBackgroundServiceMockConfiguration) {
        self.init()

        let subject = CurrentValueSubject<ChatBackground, Never>(configuration.background)
        backgroundPublisherRoomIDReturnValue = subject.asCurrentValuePublisher()
        setRoomProxyClosure = { background, _ in
            subject.send(background)
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
