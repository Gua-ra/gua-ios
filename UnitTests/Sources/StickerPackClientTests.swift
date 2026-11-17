//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

@testable import ElementX
import Foundation
import Testing

final class StickerPackClientTests {
    init() {
        StickersHTTPStub.reset()
    }
    
    @Test
    func readsEveryPackOfTheChatWhateverItsStateKey() async throws {
        StickersHTTPStub.respond(path: "/_matrix/client/v3/rooms/!room:gua.global/state", body: """
        [{"type":"m.room.name","state_key":"","content":{"name":"Family"}},
         {"type":"m.room.image_pack","state_key":"","content":{"images":{"wave":{"url":"mxc://gua.global/cat"}}}},
         {"type":"m.room.image_pack","state_key":"cats","content":{"images":{"blep":{"url":"mxc://gua.global/dog"}}}},
         {"type":"m.room.image_pack","state_key":"removed","content":{}},
         {"type":"im.ponies.room_emotes","state_key":"old","content":{"images":{"a":{"url":"mxc://gua.global/fox"}}}}]
        """)
        let client = StickerPackClient(session: URLSession(configuration: StickersHTTPStub.sessionConfiguration()),
                                       homeserver: { "https://matrix.gua.global/" },
                                       accessToken: { "token" })
        
        let events = try await client.packEvents(roomID: "!room:gua.global").get()
        
        #expect(events.map(\.eventType) == ["m.room.image_pack", "m.room.image_pack", "im.ponies.room_emotes"])
        #expect(events.map(\.stateKey) == ["", "cats", "old"])
        let request = try #require(StickersHTTPStub.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        #expect(request.url?.host() == "matrix.gua.global")
    }
    
    @Test
    func withoutATokenNothingIsRequested() async {
        let client = StickerPackClient(session: URLSession(configuration: StickersHTTPStub.sessionConfiguration()),
                                       homeserver: { "https://matrix.gua.global" },
                                       accessToken: { nil })
        
        guard case .failure(.missingAccessToken) = await client.packEvents(roomID: "!room:gua.global") else {
            Issue.record("Expected a missing token")
            return
        }
        #expect(StickersHTTPStub.requests.isEmpty)
    }
}
