//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

nonisolated struct StickerFile: Hashable, Sendable {
    let data: Data
    let mimeType: String
    let pixelWidth: Int
    let pixelHeight: Int
    let isAnimated: Bool
}

enum StickerSenderError: Error {
    case uploadFailed(ClientProxyError)
    case sendFailed(RoomProxyError)
}

// sourcery: AutoMockable
protocol StickerSenderProtocol {
    /// Uploads the file as plain media, since a sticker is shared media by definition.
    func upload(_ file: StickerFile, body: String) async -> Result<StickerImage, StickerSenderError>
    /// Returns the event ID once the server has it, as an `m.sticker` has no local echo.
    func send(_ image: StickerImage, relation: StickerRelation?) async -> Result<String, StickerSenderError>
}

final class StickerSender: StickerSenderProtocol {
    private let roomProxy: JoinedRoomProxyProtocol
    private let clientProxy: ClientProxyProtocol
    
    init(roomProxy: JoinedRoomProxyProtocol, clientProxy: ClientProxyProtocol) {
        self.roomProxy = roomProxy
        self.clientProxy = clientProxy
    }
    
    func upload(_ file: StickerFile, body: String) async -> Result<StickerImage, StickerSenderError> {
        await clientProxy.uploadMedia(data: file.data, mimeType: file.mimeType)
            .map { url in
                StickerImage(url: url,
                             body: body,
                             mimetype: file.mimeType,
                             pixelWidth: file.pixelWidth,
                             pixelHeight: file.pixelHeight,
                             size: file.data.count,
                             isAnimated: file.isAnimated)
            }
            .mapError(StickerSenderError.uploadFailed)
    }
    
    func send(_ image: StickerImage, relation: StickerRelation?) async -> Result<String, StickerSenderError> {
        let content = StickerMessageContent(image: image, relation: relation)
        return await roomProxy.sendRaw(eventType: StickerMessageContent.eventType, content: content.json.jsonString)
            .mapError(StickerSenderError.sendFailed)
    }
}
