//
// Copyright 2023, 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import XCTest

class AppRouteURLParserTests: XCTestCase {
    var appSettings: AppSettings!
    var appRouteURLParser: AppRouteURLParser!
    
    override func setUp() {
        AppSettings.resetAllSettings()
        appSettings = AppSettings()
        appRouteURLParser = AppRouteURLParser(appSettings: appSettings)
    }
    
    func testCallLinksAreNotRouted() {
        for link in ["https://call.element.io/test",
                     "https://somecustomdomain.element.io/test",
                     "io.element.call:/?url=https%3A%2F%2Fcall.element.io%2Ftest",
                     "io.element.call:/?url=https%3A%2F%2Fexample.com%2Fcall",
                     "io.element.call:/?url=http%3A%2F%2Fcall.element.io%2Ftest"] {
            guard let url = URL(string: link) else {
                XCTFail("URL invalid")
                return
            }
            
            XCTAssertNil(appRouteURLParser.route(from: url))
        }
    }
    
    func testMatrixUserURL() {
        let userID = "@test:matrix.org"
        guard let url = URL(string: "https://matrix.to/#/\(userID)") else {
            XCTFail("Invalid url")
            return
        }
        
        let route = appRouteURLParser.route(from: url)
        
        XCTAssertEqual(route, .userProfile(userID: userID))
    }
    
    func testMatrixRoomIdentifierURL() {
        let id = "!abcdefghijklmnopqrstuvwxyz1234567890:matrix.org"
        guard let url = URL(string: "https://matrix.to/#/\(id)") else {
            XCTFail("Invalid url")
            return
        }
        
        let route = appRouteURLParser.route(from: url)
        
        XCTAssertEqual(route, .room(roomID: id, via: []))
    }
    
    func testWebRoomIDURL() {
        let id = "!abcdefghijklmnopqrstuvwxyz1234567890:matrix.org"
        guard let url = URL(string: "https://app.element.io/#/room/\(id)") else {
            XCTFail("URL invalid")
            return
        }
        
        let route = appRouteURLParser.route(from: url)
        
        XCTAssertEqual(route, .room(roomID: id, via: []))
    }
    
    func testWebUserIDURL() {
        let id = "@alice:matrix.org"
        guard let url = URL(string: "https://develop.element.io/#/user/\(id)") else {
            XCTFail("URL invalid")
            return
        }
        
        let route = appRouteURLParser.route(from: url)
        
        XCTAssertEqual(route, .userProfile(userID: id))
    }
}
