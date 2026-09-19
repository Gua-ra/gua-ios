//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import CryptoKit
@testable import ElementX
import XCTest

@MainActor
final class AccountAuthorityKeyStoreTests: XCTestCase {
    private var store: AccountAuthorityKeyStore!
    private let accountID = "ga1aea6aqb5opmzmutench3ggzepkhgwmkajb3epqqrhckkf7bcbcwl2cy"

    override func setUp() {
        store = AccountAuthorityKeyStore(service: KeychainControllerService.tests.genesisID,
                                         accessGroup: InfoPlistReader.main.keychainAccessGroupIdentifier)
        store.removeKeys(forAccountID: accountID)
    }

    override func tearDown() {
        store.removeKeys(forAccountID: accountID)
    }

    func testGeneratedKeysAreDistinct() {
        let keyPair = store.generateKeyPair()
        XCTAssertNotEqual(keyPair.authority.publicKey.rawRepresentation,
                          keyPair.recovery.publicKey.rawRepresentation,
                          "The recovery authority key must differ from the authority key; a genesis committing one key twice is refused.")
        XCTAssertEqual(keyPair.authority.publicKey.rawRepresentation.count, AccountGenesis.publicKeyLength)
    }

    func testKeyPairRoundTripsThroughTheKeychain() throws {
        let keyPair = store.generateKeyPair()
        try store.persist(keyPair, forAccountID: accountID)

        let loaded = try store.authorityKey(forAccountID: accountID)
        XCTAssertEqual(loaded.publicKey.rawRepresentation, keyPair.authority.publicKey.rawRepresentation)

        // The key that comes back signs what the original would have signed.
        let message = Data("attach preimage stand-in".utf8)
        let signature = try loaded.signature(for: message)
        XCTAssertTrue(keyPair.authority.publicKey.isValidSignature(signature, for: message))
    }

    func testLoadingAnUnknownAccountReportsTheKeyMissing() {
        XCTAssertThrowsError(try store.authorityKey(forAccountID: "ga1aeatmvszaxoxcnsrkzpzbvaust6jcdhcapmia7snhqrspmukdojzkgq")) { error in
            XCTAssertEqual(error as? AccountAuthorityKeyStoreError, .keyMissing)
        }
    }

    func testRemovingKeysMakesTheAuthorityKeyMissing() throws {
        try store.persist(store.generateKeyPair(), forAccountID: accountID)
        XCTAssertNoThrow(try store.authorityKey(forAccountID: accountID))

        store.removeKeys(forAccountID: accountID)

        XCTAssertThrowsError(try store.authorityKey(forAccountID: accountID)) { error in
            // A signup that reaches the attach step with no key must fail, never fall back to a
            // bootstrap account (ADM-008 decision 6).
            XCTAssertEqual(error as? AccountAuthorityKeyStoreError, .keyMissing)
        }
    }

    func testKeysForDifferentAccountsDoNotCollide() throws {
        let other = "ga1aeatmvszaxoxcnsrkzpzbvaust6jcdhcapmia7snhqrspmukdojzkgq"
        defer { store.removeKeys(forAccountID: other) }

        let first = store.generateKeyPair()
        let second = store.generateKeyPair()
        try store.persist(first, forAccountID: accountID)
        try store.persist(second, forAccountID: other)

        XCTAssertEqual(try store.authorityKey(forAccountID: accountID).publicKey.rawRepresentation,
                       first.authority.publicKey.rawRepresentation)
        XCTAssertEqual(try store.authorityKey(forAccountID: other).publicKey.rawRepresentation,
                       second.authority.publicKey.rawRepresentation)
    }
}
