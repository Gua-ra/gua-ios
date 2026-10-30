//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum RosterForm: String {
    case v1
    /// Older resolvers sign the bytes without the search fields.
    case legacy
}

/// The `gua-roster.v1` bytes the authority signs, byte for byte as the resolver's `CanonicalRoster`.
/// Null and empty collapse in this form, so it is never reused for a new signed object.
enum CanonicalRoster {
    private static let separator = "\u{1F}"

    static func form(of roster: SignedRosterDocument) -> RosterForm? {
        let withSearchFields = roster.entries.filter(\.homeserver.hasSearchVisibilityField).count
        if withSearchFields == 0 { return .legacy }
        if withSearchFields == roster.entries.count { return .v1 }
        return nil
    }

    static func bytes(of roster: SignedRosterDocument, form: RosterForm) -> [UInt8]? {
        guard let issuedAt = ResolverInstant(iso: roster.issuedAt) else { return nil }
        var text = "gua-roster.v1\n"
        text += "version=\(roster.version)\n"
        text += "issuedAt=\(issuedAt.epochMilliseconds)\n"
        text += "log=\(roster.logCheckpoint.merkleRoot):\(roster.logCheckpoint.size)\n"
        let entries = roster.entries.sorted { JavaStringOrder.compare($0.homeserver.id, $1.homeserver.id) < 0 }
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
        // Java's StringJoiner writes a null as the text null.
        var fields = [homeserver.id ?? "null",
                      homeserver.serverName ?? "null",
                      homeserver.baseUrl ?? "null",
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
        let sorted = claims.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            let byCountry = JavaStringOrder.compare(lhs.country ?? "", rhs.country ?? "")
            if byCountry != 0 { return byCountry < 0 }
            let byMccmnc = JavaStringOrder.compare(lhs.mccmnc ?? "", rhs.mccmnc ?? "")
            if byMccmnc != 0 { return byMccmnc < 0 }
            return JavaStringOrder.compare(lhs.affiliation ?? "", rhs.affiliation ?? "") < 0
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
