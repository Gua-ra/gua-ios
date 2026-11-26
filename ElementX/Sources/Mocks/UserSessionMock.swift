//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation

struct UserSessionMockConfiguration {
    var clientProxy: ClientProxyProtocol = ClientProxyMock(.init())
    var chatBackgroundService: ChatBackgroundServiceProtocol = ChatBackgroundServiceMock(.init())
}

extension UserSessionMock {
    convenience init(_ configuration: UserSessionMockConfiguration) {
        self.init()
        
        clientProxy = configuration.clientProxy
        mediaProvider = MediaProviderMock(configuration: .init())
        voiceMessageMediaManager = VoiceMessageMediaManagerMock()
        chatBackgroundService = configuration.chatBackgroundService
        
        sessionSecurityStatePublisher = CurrentValueSubject<SessionSecurityState, Never>(.init(verificationState: .verified, recoveryState: .enabled)).asCurrentValuePublisher()
    }
}
