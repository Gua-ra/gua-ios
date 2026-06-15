//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Contacts
import Foundation

/// A contact from the device address book that has been matched to a Gua account.
struct DiscoveredContact: Identifiable, Equatable {
    /// The name as it appears in the user's address book (falls back to the Gua display name).
    let localName: String
    let phoneNumber: String
    let userId: String
    let username: String?

    var id: String { userId }

    /// What to show as the handle line, preferring the global username.
    var handle: String {
        if let username, !username.isEmpty { return "@\(username)" }
        return userId
    }
}

enum ContactDiscoveryError: Error, LocalizedError {
    case accessDenied
    case noContactsWithNumbers
    case lookupFailed(Error)

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            "Gua needs access to your contacts to find which of them are already here. You can enable it in Settings."
        case .noContactsWithNumbers:
            "None of your contacts have a phone number we can check."
        case let .lookupFailed(error):
            (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

@MainActor
protocol ContactDiscoveryServiceProtocol {
    var authorizationStatus: CNAuthorizationStatus { get }
    func requestAccess() async -> Bool
    /// Reads the address book, normalizes numbers to E.164, and returns the contacts that are on Gua.
    func discover(accessToken: String) async throws -> [DiscoveredContact]
}

@MainActor
final class ContactDiscoveryService: ContactDiscoveryServiceProtocol {
    private let identityServiceClient: IdentityServiceClientProtocol
    private let store = CNContactStore()

    /// Identity-service caps the batch; stay under it.
    private let maxNumbersPerRequest = 1000

    init(identityServiceClient: IdentityServiceClientProtocol) {
        self.identityServiceClient = identityServiceClient
    }

    var authorizationStatus: CNAuthorizationStatus {
        CNContactStore.authorizationStatus(for: .contacts)
    }

    func requestAccess() async -> Bool {
        if authorizationStatus == .authorized { return true }
        return await withCheckedContinuation { continuation in
            store.requestAccess(for: .contacts) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    func discover(accessToken: String) async throws -> [DiscoveredContact] {
        guard await requestAccess() else { throw ContactDiscoveryError.accessDenied }

        // Map every normalized E.164 number to the best local name so matches can be
        // labelled with how the user actually knows the person.
        let nameByNumber = readAddressBook()
        guard !nameByNumber.isEmpty else { throw ContactDiscoveryError.noContactsWithNumbers }

        let phones = Array(nameByNumber.keys.prefix(maxNumbersPerRequest))
        let matches: [ContactMatch]
        do {
            matches = try await identityServiceClient.lookupContacts(accessToken: accessToken, phones: phones)
        } catch {
            throw ContactDiscoveryError.lookupFailed(error)
        }

        return matches
            .map { match in
                DiscoveredContact(localName: nameByNumber[match.phoneNumber] ?? match.displayName ?? match.username ?? match.userId,
                                  phoneNumber: match.phoneNumber,
                                  userId: match.userId,
                                  username: match.username)
            }
            .sorted { $0.localName.localizedCaseInsensitiveCompare($1.localName) == .orderedAscending }
    }

    // MARK: - Address book

    private func readAddressBook() -> [String: String] {
        // Use the formatter's own descriptor so every key it reads (given/middle/family,
        // prefix/suffix, …) is fetched — otherwise CNContactFormatter throws when it touches
        // an unfetched property.
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactPhoneNumbersKey as CNKeyDescriptor
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        let defaultDialCode = Country.deviceDefault.dialCode

        var nameByNumber: [String: String] = [:]
        do {
            try store.enumerateContacts(with: request) { contact, _ in
                let name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
                for labelled in contact.phoneNumbers {
                    guard let e164 = Self.normalizeToE164(labelled.value.stringValue, defaultDialCode: defaultDialCode) else { continue }
                    // First non-empty name wins; never overwrite a real name with a blank.
                    if nameByNumber[e164] == nil || (nameByNumber[e164]?.isEmpty ?? true) {
                        nameByNumber[e164] = name.isEmpty ? e164 : name
                    }
                }
            }
        } catch {
            MXLog.warning("Failed to enumerate contacts: \(error)")
        }
        return nameByNumber
    }

    /// Best-effort E.164 normalization for an address-book number. International numbers
    /// (with `+` or `00`) are used as-is; national numbers get the device region's dial code
    /// with a single trunk `0` dropped. The server validates and silently skips anything that
    /// still isn't valid E.164, so over-normalizing is harmless.
    static func normalizeToE164(_ raw: String, defaultDialCode: String) -> String? {
        var cleaned = raw.filter { $0.isNumber || $0 == "+" }
        if cleaned.hasPrefix("+") {
            // already international
        } else if cleaned.hasPrefix("00") {
            cleaned = "+" + cleaned.dropFirst(2)
        } else {
            var national = cleaned
            if national.hasPrefix("0") { national = String(national.dropFirst()) }
            cleaned = "+" + defaultDialCode + national
        }
        let isE164 = cleaned.range(of: "^\\+[1-9]\\d{6,14}$", options: .regularExpression) != nil
        return isE164 ? cleaned : nil
    }
}
