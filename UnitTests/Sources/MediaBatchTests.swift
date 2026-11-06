//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

struct MediaBatchTests {
    @Test
    func fixtureMarkers() throws {
        for fixture in try MediaBatchFixtures.load().markers {
            let content = try #require(fixture["content"] as? [String: Any])
            let name = try #require(fixture["name"] as? String)
            #expect(MediaBatch(content: content) == Self.batch(from: fixture["batch"]), Comment(rawValue: name))
        }
    }
    
    @Test
    func eventJSONIsReadFromItsContent() {
        let eventJSON = #"{"type":"m.room.message","content":{"msgtype":"m.video","body":"a.mp4","global.gua.batch":{"v":1,"id":"b1","index":1,"count":3}}}"#
        #expect(MediaBatch(eventJSON: eventJSON) == MediaBatch(id: "b1", index: 1, count: 3))
    }
    
    @Test
    func extraContentRoundTrips() throws {
        let batch = MediaBatch(id: "5b0f3c8e-1d2a-4c6b-9f3e-2a7d8c1b4e60", index: 2, count: 4)
        var content = try #require(JSONSerialization.jsonObject(with: Data(batch.extraContentJSON.utf8)) as? [String: Any])
        content["msgtype"] = "m.image"
        
        #expect(MediaBatch(content: content) == batch)
    }
    
    @Test
    func newBatchesShareAnIDInPickOrder() throws {
        let batch = try MediaBatch.makeBatches(count: 3).map { try #require($0) }
        
        #expect(Set(batch.map(\.id)).count == 1)
        #expect(batch.map(\.index) == [0, 1, 2])
        #expect(batch.allSatisfy { $0.count == 3 })
        #expect(batch[0].id == batch[0].id.lowercased())
    }
    
    @Test
    func largeSendsSplitIntoBatchesOfTwenty() {
        let batches = MediaBatch.makeBatches(count: 41)
        
        #expect(batches.prefix(40).map { $0?.count } == Array(repeating: 20, count: 40))
        #expect(Set(batches.prefix(40).compactMap { $0?.id }).count == 2)
        #expect(batches[40] == nil, "A lone last item is sent on its own.")
        #expect(MediaBatch.makeBatches(count: 1) == [nil])
    }
    
    private static func batch(from value: Any?) -> MediaBatch? {
        guard let batch = value as? [String: Any],
              let id = batch["id"] as? String, let index = batch["index"] as? Int, let count = batch["count"] as? Int else {
            return nil
        }
        return MediaBatch(id: id, index: index, count: count)
    }
}

/// `media-batch-v1-fixtures.json`, byte-identical to the copy in gua-android.
struct MediaBatchFixtures {
    let markers: [[String: Any]]
    let grouping: [[String: Any]]
    
    static func load() throws -> MediaBatchFixtures {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "media-batch-v1-fixtures.json", withExtension: nil))
        let fixtures = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try MediaBatchFixtures(markers: #require(fixtures["markers"] as? [[String: Any]]),
                                      grouping: #require(fixtures["grouping"] as? [[String: Any]]))
    }
    
    private final class BundleToken { }
}
