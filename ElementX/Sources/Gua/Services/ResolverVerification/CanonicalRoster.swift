//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum RosterForm: String {
    /// Entries carry `searchVisibility` and `searchGroups`.
    case v1
    /// Entries from a resolver image before 2026-08-14, whose signature covers bytes without the search fields.
    case legacy
}

/// The `gua-roster.v1` bytes the authority signs, byte for byte as the resolver's `CanonicalRoster`. Fields are
/// joined by U+001F and null and empty collapse, so this form is never reused for a new signed object.
enum CanonicalRoster {
    private static let separator = "\u{1F}"

    /// `nil` when the entries mix the two forms: a verifier does not guess.
    static func form(of roster: SignedRosterDocument) -> RosterForm? {
        let withSearchFields = roster.entries.filter(\.homeserver.hasSearchVisibilityField).count
        if withSearchFields == 0 { return .legacy }
        if withSearchFields == roster.entries.count { return .v1 }
        return nil
    }

    /// `nil` when a timestamp the bytes carry does not parse.
    static func bytes(of roster: SignedRosterDocument, form: RosterForm) -> [UInt8]? {
        guard let issuedAt = ResolverInstant(iso: roster.issuedAt) else { return nil }
        var text = "gua-roster.v1\n"
        text += "version=\(roster.version)\n"
        text += "issuedAt=\(issuedAt.epochMilliseconds)\n"
        text += "log=\(roster.logCheckpoint.merkleRoot):\(roster.logCheckpoint.size)\n"
        let entries = roster.entries.stableSorted { JavaStringOrder.compare($0.homeserver.id, $1.homeserver.id) }
        for entry in entries {
            guard let line = entryLine(entry, searchFields: form == .v1) else { return nil }
            text += line + "\n"
        }
        return Array(text.utf8)
    }

    private static func entryLine(_ entry: SignedRosterEntry, searchFields: Bool) -> String? {
        let homeserver = entry.homeserver
        var admittedAt = ""
        if let iso = entry.admittedAt {
            guard let instant = ResolverInstant(iso: iso) else { return nil }
            admittedAt = String(instant.epochMilliseconds)
        }
        var fields = [homeserver.id,
                      homeserver.serverName,
                      homeserver.baseUrl,
                      homeserver.masIssuer ?? "null",
                      homeserver.region ?? "",
                      String(homeserver.weight),
                      homeserver.acceptsNew ? "true" : "false",
                      homeserver.signingKey ?? ""]
        if searchFields {
            fields.append(homeserver.searchVisibility)
            fields.append(JavaStringOrder.sorted(homeserver.searchGroups).joined(separator: "|"))
        }
        fields.append(admittedAt)
        fields.append(entry.status)
        fields.append(claims(entry.claims))
        return fields.joined(separator: separator)
    }

    private static func claims(_ claims: [RosterClaimPredicate]) -> String {
        if claims.isEmpty { return "[]" }
        let sorted = claims.stableSorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority ? -1 : 1 }
            let byCountry = JavaStringOrder.compare(lhs.country ?? "", rhs.country ?? "")
            if byCountry != 0 { return byCountry }
            let byMccmnc = JavaStringOrder.compare(lhs.mccmnc ?? "", rhs.mccmnc ?? "")
            if byMccmnc != 0 { return byMccmnc }
            return JavaStringOrder.compare(lhs.affiliation ?? "", rhs.affiliation ?? "")
        }
        return sorted.map(claim).joined(separator: ";")
    }

    private static func claim(_ claim: RosterClaimPredicate) -> String {
        let prefixes = claim.phonePrefixes.map { JavaStringOrder.sorted($0).joined(separator: "|") } ?? ""
        return ["country=" + (claim.country ?? ""),
                "mccmnc=" + (claim.mccmnc ?? ""),
                "carrier=" + (claim.carrier ?? ""),
                "prefixes=" + prefixes,
                "affiliation=" + (claim.affiliation ?? ""),
                "attrs=" + attributes(claim.attributeMatch),
                "remote=" + (claim.remoteClaimUrl ?? ""),
                "priority=" + String(claim.priority)].joined(separator: ",")
    }

    private static func attributes(_ attributes: [String: String]?) -> String {
        guard let attributes else { return "" }
        return attributes.sorted { JavaStringOrder.precedes($0.key, $1.key) }.map { "\($0.key)=\($0.value)" }.joined(separator: "|")
    }
}

extension Array {
    /// Java's `sorted` is stable; Swift's documents no such guarantee, so equal keys keep their input order here.
    func stableSorted(by compare: (Element, Element) -> Int) -> [Element] {
        enumerated()
            .sorted { lhs, rhs in
                let order = compare(lhs.element, rhs.element)
                return order != 0 ? order < 0 : lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
