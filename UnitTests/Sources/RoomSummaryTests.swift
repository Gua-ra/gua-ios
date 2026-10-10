//
// Copyright 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import XCTest

class RoomSummaryTests: XCTestCase {
    // swiftlint:disable:next large_tuple
    let roomDetails: (id: String, name: String, avatarURL: URL) = ("room_id", "Room Name", "mxc://hs.tld/room/avatar")
    let heroes = [UserProfileProxy(userID: "hero_1", displayName: "Hero 1", avatarURL: "mxc://hs.tld/user/avatar")]
    
    func testRoomAvatar() {
        let details = makeSummary(isDirect: false, hasRoomAvatar: true, isTombstoned: false)
        
        switch details.avatar {
        case .room(let id, let name, let avatarURL):
            XCTAssertEqual(id, roomDetails.id)
            XCTAssertEqual(name, roomDetails.name)
            XCTAssertEqual(avatarURL, roomDetails.avatarURL)
        case .heroes:
            XCTFail("A room shouldn't use the heroes for its avatar.")
        case .space:
            XCTFail("A room shouldn't use a space avatar.")
        case .tombstoned:
            XCTFail("A room shouldn't use the tombstone for its avatar.")
        }
    }
    
    func testDMAvatarSet() {
        let details = makeSummary(isDirect: true, hasRoomAvatar: true, isTombstoned: false)
        
        switch details.avatar {
        case .room(let id, let name, let avatarURL):
            XCTAssertEqual(id, roomDetails.id)
            XCTAssertEqual(name, roomDetails.name)
            XCTAssertEqual(avatarURL, roomDetails.avatarURL)
        case .heroes:
            XCTFail("A DM with an avatar set shouldn't use the heroes instead.")
        case .space:
            XCTFail("A DM shouldn't use a space avatar.")
        case .tombstoned:
            XCTFail("A room shouldn't use the tombstone for its avatar.")
        }
    }
    
    func testDMAvatarNotSet() {
        let details = makeSummary(isDirect: true, hasRoomAvatar: false, isTombstoned: false)
        
        switch details.avatar {
        case .room:
            XCTFail("A DM without an avatar should defer to the hero for the correct placeholder tint colour.")
        case .heroes(let heroes):
            XCTAssertEqual(heroes, self.heroes)
        case .space:
            XCTFail("A DM shouldn't use a space avatar.")
        case .tombstoned:
            XCTFail("A room shouldn't use the tombstone for its avatar.")
        }
    }
    
    func testTombstonedAvatar() {
        let details = makeSummary(isDirect: false, hasRoomAvatar: true, isTombstoned: true)
        
        XCTAssertEqual(details.avatar, .tombstoned)
    }

    func testUnnamedRoomWithNobodyElseAndNothingToPreviewIsAnOrphan() {
        XCTAssertTrue(makeOrphanCandidate(activeMembersCount: 1).isEmptyOrphanRoom)
        XCTAssertTrue(makeOrphanCandidate(activeMembersCount: 2).isEmptyOrphanRoom)
    }

    func testNamedRoomWithoutPreviewIsNotAnOrphan() {
        // Messages this device cannot decrypt leave no preview, and the server sends no heroes for a named room.
        XCTAssertFalse(makeOrphanCandidate(activeMembersCount: 1, hasExplicitName: true).isEmptyOrphanRoom)
        XCTAssertFalse(makeOrphanCandidate(activeMembersCount: 2, hasExplicitName: true).isEmptyOrphanRoom)
    }

    func testRoomWithSomethingToShowIsNotAnOrphan() {
        XCTAssertFalse(makeOrphanCandidate(activeMembersCount: 2, heroes: heroes).isEmptyOrphanRoom)
        XCTAssertFalse(makeOrphanCandidate(activeMembersCount: 1, lastMessage: "Hello").isEmptyOrphanRoom)
        XCTAssertFalse(makeOrphanCandidate(activeMembersCount: 3).isEmptyOrphanRoom)
        XCTAssertFalse(makeOrphanCandidate(activeMembersCount: 1, joinRequestType: .knock).isEmptyOrphanRoom)
    }

    // MARK: - Helpers

    func makeOrphanCandidate(activeMembersCount: UInt,
                             heroes: [UserProfileProxy] = [],
                             lastMessage: AttributedString? = nil,
                             joinRequestType: RoomSummary.JoinRequestType? = nil,
                             hasExplicitName: Bool = false) -> RoomSummary {
        RoomSummary(room: .init(noHandle: .init()),
                    id: roomDetails.id,
                    joinRequestType: joinRequestType,
                    name: roomDetails.name,
                    isDirect: false,
                    avatarURL: nil,
                    heroes: heroes,
                    activeMembersCount: activeMembersCount,
                    lastMessage: lastMessage,
                    lastMessageDate: nil,
                    unreadMessagesCount: 0,
                    unreadMentionsCount: 0,
                    unreadNotificationsCount: 0,
                    notificationMode: nil,
                    canonicalAlias: nil,
                    alternativeAliases: [],
                    hasOngoingCall: false,
                    isMarkedUnread: false,
                    isFavourite: false,
                    isTombstoned: false,
                    hasExplicitName: hasExplicitName)
    }
    
    func makeSummary(isDirect: Bool, hasRoomAvatar: Bool, isTombstoned: Bool) -> RoomSummary {
        RoomSummary(room: .init(noHandle: .init()),
                    id: roomDetails.id,
                    joinRequestType: nil,
                    name: roomDetails.name,
                    isDirect: isDirect,
                    avatarURL: hasRoomAvatar ? roomDetails.avatarURL : nil,
                    heroes: heroes,
                    activeMembersCount: 0,
                    lastMessage: nil,
                    lastMessageDate: nil,
                    unreadMessagesCount: 0,
                    unreadMentionsCount: 0,
                    unreadNotificationsCount: 0,
                    notificationMode: nil,
                    canonicalAlias: nil,
                    alternativeAliases: [],
                    hasOngoingCall: false,
                    isMarkedUnread: false,
                    isFavourite: false,
                    isTombstoned: isTombstoned)
    }
}
