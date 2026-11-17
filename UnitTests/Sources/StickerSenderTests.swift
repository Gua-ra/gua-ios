//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

@testable import ElementX
import Foundation
import Testing

@MainActor
final class StickerSenderTests {
    private let file = StickerFile(data: Data(repeating: 1, count: 4000), mimeType: "image/png", pixelWidth: 512, pixelHeight: 301, isAnimated: false)
    
    private var clientProxy: ClientProxyMock!
    private var roomProxy: JoinedRoomProxyMock!
    private var sender: StickerSender!
    
    init() {
        clientProxy = ClientProxyMock(.init())
        roomProxy = JoinedRoomProxyMock(.init())
        sender = StickerSender(roomProxy: roomProxy, clientProxy: clientProxy)
    }
    
    @Test
    func uploadIsPlainMediaWithTheDisplaySize() async throws {
        clientProxy.uploadMediaDataMimeTypeReturnValue = .success("mxc://gua.global/new")
        
        let image = try await sender.upload(file, body: "Cat").get()
        
        #expect(clientProxy.uploadMediaDataMimeTypeReceivedArguments?.mimeType == "image/png")
        #expect(clientProxy.uploadMediaDataMimeTypeReceivedArguments?.data == file.data)
        #expect(image.json == .object(["body": .string("Cat"),
                                       "info": .object(["h": .int(151), "mimetype": .string("image/png"), "size": .int(4000), "w": .int(256)]),
                                       "url": .string("mxc://gua.global/new")]))
    }
    
    @Test
    func failedUploadIsReported() async {
        clientProxy.uploadMediaDataMimeTypeReturnValue = .failure(.invalidMedia)
        
        guard case .failure(.uploadFailed) = await sender.upload(file, body: "Cat") else {
            Issue.record("Expected the upload to fail")
            return
        }
    }
    
    @Test
    func sendsARawStickerEventInReplyAndInThreads() async throws {
        roomProxy.sendRawEventTypeContentReturnValue = .success("$sticker")
        let image = StickerImage(url: "mxc://gua.global/cat", body: "Cat", info: StickerImageInfo(width: 256, height: 256, mimetype: "image/png", size: 1000))
            .with(added: 1)
        
        let eventID = try await sender.send(image, relation: .reply(eventID: "$reply")).get()
        
        #expect(eventID == "$sticker")
        #expect(roomProxy.sendRawEventTypeContentReceivedArguments?.eventType == "m.sticker")
        #expect(roomProxy.sendRawEventTypeContentReceivedArguments?.content
            == #"{"body":"Cat","info":{"h":256,"mimetype":"image/png","size":1000,"w":256},"m.relates_to":{"m.in_reply_to":{"event_id":"$reply"}},"url":"mxc://gua.global/cat"}"#)
        
        _ = await sender.send(image, relation: .thread(rootEventID: "$root", latestEventID: "$latest"))
        let threadContent = try #require(JSONValue(jsonString: roomProxy.sendRawEventTypeContentReceivedArguments?.content)?.objectValue)
        #expect(threadContent["m.relates_to"] == .object(["event_id": .string("$root"),
                                                          "is_falling_back": .bool(true),
                                                          "m.in_reply_to": .object(["event_id": .string("$latest")]),
                                                          "rel_type": .string("m.thread")]))
    }
    
    @Test
    func stickerWithoutABodyIsSentAsSticker() async throws {
        roomProxy.sendRawEventTypeContentReturnValue = .success("$sticker")
        
        _ = await sender.send(StickerImage(url: "mxc://gua.global/cat", body: nil, info: nil), relation: nil)
        
        let content = try #require(JSONValue(jsonString: roomProxy.sendRawEventTypeContentReceivedArguments?.content))
        #expect(content == .object(["body": .string("Sticker"), "info": .object([:]), "url": .string("mxc://gua.global/cat")]))
    }
    
    @Test
    func failedSendIsReported() async {
        roomProxy.sendRawEventTypeContentReturnValue = .failure(.eventNotFound)
        
        guard case .failure(.sendFailed) = await sender.send(StickerImage(url: "mxc://gua.global/cat", body: "Cat", info: nil), relation: nil) else {
            Issue.record("Expected the send to fail")
            return
        }
    }
}
