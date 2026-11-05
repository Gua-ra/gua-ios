//
// Copyright Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

final class IdentityResetMarkerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    
    @Test
    func aFreshMarkerStandsTheExtensionDown() {
        #expect(IdentityResetMarker.isFresh(startedAt: now.addingTimeInterval(-5), now: now))
        #expect(IdentityResetMarker.isFresh(startedAt: now.addingTimeInterval(-(IdentityResetMarker.maxAge - 1)), now: now))
    }
    
    @Test
    func anExpiredMarkerDoesNot() {
        #expect(!IdentityResetMarker.isFresh(startedAt: now.addingTimeInterval(-IdentityResetMarker.maxAge), now: now))
        #expect(!IdentityResetMarker.isFresh(startedAt: now.addingTimeInterval(-3600), now: now))
    }
    
    @Test
    func anAbsentMarkerDoesNot() {
        #expect(!IdentityResetMarker.isFresh(startedAt: nil, now: now))
    }
    
    @Test
    func aFutureMarkerIsTrustedOnlyWithinTolerance() {
        #expect(IdentityResetMarker.isFresh(startedAt: now.addingTimeInterval(IdentityResetMarker.futureTolerance - 1), now: now))
        #expect(!IdentityResetMarker.isFresh(startedAt: now.addingTimeInterval(IdentityResetMarker.futureTolerance + 1), now: now))
    }
    
    @Test
    func theMarkerIsAccountSpecific() {
        let settings = AppSettings.volatile()
        settings.setIdentityResetStartedAt(now, forUserID: "@one:example.org")
        
        #expect(settings.identityResetStartedAt(forUserID: "@one:example.org") == now)
        #expect(settings.identityResetStartedAt(forUserID: "@two:example.org") == nil)
        
        settings.setIdentityResetStartedAt(nil, forUserID: "@one:example.org")
        #expect(settings.identityResetStartedAt(forUserID: "@one:example.org") == nil)
    }
}
