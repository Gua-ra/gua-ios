//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import CryptoKit
@testable import ElementX
import Foundation
import Testing

@MainActor
final class AccountAuthorityKeyStoreTests {
    private var store: AccountAuthorityKeyStore!
    private let accountID = "ga1aea6aqb5opmzmutench3ggzepkhgwmkajb3epqqrhckkf7bcbcwl2cy"
    
    init() {
        store = AccountAuthorityKeyStore(service: KeychainControllerService.tests.genesisID,
                                         accessGroup: InfoPlistReader.main.keychainAccessGroupIdentifier)
        store.removeKeys(forAccountID: accountID)
    }
    
    isolated deinit {
        store.removeKeys(forAccountID: accountID)
    }
    
    @Test
    func generatedKeysAreDistinct() {
        let keyPair = store.generateKeyPair()
        #expect(keyPair.authority.publicKey.rawRepresentation != keyPair.recovery.publicKey.rawRepresentation, "The recovery authority key must differ from the authority key; a genesis committing one key twice is refused.")
        #expect(keyPair.authority.publicKey.rawRepresentation.count == AccountGenesis.publicKeyLength)
    }
    
    @Test
    func keyPairRoundTripsThroughTheKeychain() throws {
        let keyPair = store.generateKeyPair()
        try store.persist(keyPair, forAccountID: accountID)
        
        let loaded = try store.authorityKey(forAccountID: accountID)
        #expect(loaded.publicKey.rawRepresentation == keyPair.authority.publicKey.rawRepresentation)
        
        // The key that comes back signs what the original would have signed.
        let message = Data("attach preimage stand-in".utf8)
        let signature = try loaded.signature(for: message)
        #expect(keyPair.authority.publicKey.isValidSignature(signature, for: message))
    }
    
    @Test
    func loadingAnUnknownAccountReportsTheKeyMissing() throws {
        let error = try #require(throws: (any Error).self) {
            try store.authorityKey(forAccountID: "ga1aeatmvszaxoxcnsrkzpzbvaust6jcdhcapmia7snhqrspmukdojzkgq")
        }
        #expect(error as? AccountAuthorityKeyStoreError == .keyMissing)
    }
    
    @Test
    func removingKeysMakesTheAuthorityKeyMissing() throws {
        try store.persist(store.generateKeyPair(), forAccountID: accountID)
        #expect(throws: Never.self) {
            try store.authorityKey(forAccountID: accountID)
        }
        
        store.removeKeys(forAccountID: accountID)
        
        let error = try #require(throws: (any Error).self) {
            try store.authorityKey(forAccountID: accountID)
        }
        // A signup that reaches the attach step with no key must fail, never fall back to a
        // bootstrap account (ADM-008 decision 6).
        #expect(error as? AccountAuthorityKeyStoreError == .keyMissing)
    }
    
    @Test
    func keysForDifferentAccountsDoNotCollide() throws {
        let other = "ga1aeatmvszaxoxcnsrkzpzbvaust6jcdhcapmia7snhqrspmukdojzkgq"
        defer { store.removeKeys(forAccountID: other) }
        
        let first = store.generateKeyPair()
        let second = store.generateKeyPair()
        try store.persist(first, forAccountID: accountID)
        try store.persist(second, forAccountID: other)
        
        #expect(try store.authorityKey(forAccountID: accountID).publicKey.rawRepresentation == first.authority.publicKey.rawRepresentation)
        #expect(try store.authorityKey(forAccountID: other).publicKey.rawRepresentation == second.authority.publicKey.rawRepresentation)
    }
}
