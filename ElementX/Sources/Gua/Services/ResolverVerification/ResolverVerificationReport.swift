//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// The raw values are the report line's codes, the same on every Gua app.
enum ResolverVerificationReason: String, Error {
    case noTrustRoots = "no_trust_roots"
    case rosterUnavailable = "roster_unavailable"
    case parseError = "parse_error"
    case mixedRosterForm = "mixed_roster_form"
    case timeout
    case unknownKeyId = "unknown_key_id"
    case badSignature = "bad_signature"
    case thresholdNotMet = "threshold_not_met"
    case rosterUnverified = "roster_unverified"
    case noMatchingEntry = "no_matching_entry"
    case unsupportedSchema = "unsupported_schema"
    case unsupportedAlg = "unsupported_alg"
    case badKeyId = "bad_key_id"
    case badSequence = "bad_sequence"
    case badWindow = "bad_window"
    case outsideWindow = "outside_window"
    case malformedSignature = "malformed_signature"
    case noCanonicalEncoding = "no_canonical_encoding"
    case badSigningKey = "bad_signing_key"
    case missingSignature = "missing_signature"
    case logUnavailable = "log_unavailable"
    case storageUnavailable = "storage_unavailable"
    case noPolicyKeys = "no_policy_keys"
    case policyUnavailable = "policy_unavailable"
    case policyNotServed = "policy_not_served"
    case logTooLarge = "log_too_large"
    case logMismatch = "log_mismatch"
    case policyNotLogged = "policy_not_logged"
    case policySuperseded = "policy_superseded"
    case policyNewerThanCheckpoint = "policy_newer_than_checkpoint"
    case existingAccount = "existing_account"
    case policyUnverified = "policy_unverified"
    case unsignedRule = "unsigned_rule"
    case unattributed
}

/// The report is logged, so it never holds the phone, the answer or a hostname.
struct ResolverVerificationReport: Equatable {
    typealias Reason = ResolverVerificationReason

    enum RosterSignature: Equatable {
        case valid
        case invalid(Reason)
        case unverifiable(Reason)
    }

    enum HomeserverMatch: Equatable {
        case activeMatch
        case inactive
        case fieldMismatch
        case notInRoster
        case unverifiable(Reason)
    }

    enum MemberEntry: Equatable {
        case valid
        case unattested
        case invalid(Reason)
        case unverifiable(Reason)
    }

    enum LogConsistency: Equatable {
        case firstSeen
        case consistent
        case rollback
        case inconsistent
        case unverifiable(Reason)
    }

    enum Policy: Equatable {
        case notPresent
        case valid
        case invalid(Reason)
        case unverifiable(Reason)
    }

    enum Placement: Equatable {
        case match
        case mismatch
        case indeterminate(Reason)
        case unverifiable(Reason)
    }

    enum Check: String {
        case rosterSignature, homeserverMatch, memberEntry, logConsistency, policy, placement
    }

    enum Overall: Equatable {
        case verified
        case failed(Check)
        case unverifiable(Check)
    }

    let environment: String
    let rosterVersion: Int64?
    let rosterForm: String?
    let rosterSignature: RosterSignature
    let homeserverMatch: HomeserverMatch
    let memberEntry: MemberEntry
    let logConsistency: LogConsistency
    let policy: Policy
    let placement: Placement
    let durationMs: Int

    var overall: Overall {
        if let failed = checks.first(where: { $0.summary.verdict == .failed }) { return .failed(failed.check) }
        if let undecided = checks.first(where: { $0.summary.verdict == .undecided }) { return .unverifiable(undecided.check) }
        return .verified
    }

    var logDescription: String {
        (["environment=\(environment)", "rosterVersion=\(rosterVersion.map(String.init) ?? "none")", "rosterForm=\(rosterForm ?? "none")"]
            + checks.map { "\($0.check.rawValue)=\($0.summary.code)" }
            + ["overall=\(overall.code)", "durationMs=\(durationMs)"])
            .joined(separator: " ")
    }

    private var checks: [(check: Check, summary: Summary)] {
        [(.rosterSignature, rosterSignature.summary), (.homeserverMatch, homeserverMatch.summary), (.memberEntry, memberEntry.summary),
         (.logConsistency, logConsistency.summary), (.policy, policy.summary), (.placement, placement.summary)]
    }
}

extension ResolverVerificationReport {
    struct Summary: Equatable {
        enum Verdict {
            case passed, failed, undecided
        }

        let code: String
        let verdict: Verdict

        static func passed(_ code: String) -> Summary {
            Summary(code: code, verdict: .passed)
        }

        static func failed(_ code: String) -> Summary {
            Summary(code: code, verdict: .failed)
        }

        static func invalid(_ reason: Reason) -> Summary {
            .failed("invalid(\(reason.rawValue))")
        }

        static func unverifiable(_ reason: Reason) -> Summary {
            Summary(code: "unverifiable(\(reason.rawValue))", verdict: .undecided)
        }

        static func indeterminate(_ reason: Reason) -> Summary {
            Summary(code: "indeterminate(\(reason.rawValue))", verdict: .undecided)
        }
    }
}

extension ResolverVerificationReport.RosterSignature {
    var summary: ResolverVerificationReport.Summary {
        switch self {
        case .valid: .passed("valid")
        case .invalid(let reason): .invalid(reason)
        case .unverifiable(let reason): .unverifiable(reason)
        }
    }
}

extension ResolverVerificationReport.HomeserverMatch {
    var summary: ResolverVerificationReport.Summary {
        switch self {
        case .activeMatch: .passed("ACTIVE_MATCH")
        case .inactive: .failed("INACTIVE")
        case .fieldMismatch: .failed("FIELD_MISMATCH")
        case .notInRoster: .failed("NOT_IN_ROSTER")
        case .unverifiable(let reason): .unverifiable(reason)
        }
    }
}

extension ResolverVerificationReport.MemberEntry {
    var summary: ResolverVerificationReport.Summary {
        switch self {
        case .valid: .passed("valid")
        case .unattested: .passed("unattested")
        case .invalid(let reason): .invalid(reason)
        case .unverifiable(let reason): .unverifiable(reason)
        }
    }
}

extension ResolverVerificationReport.LogConsistency {
    var summary: ResolverVerificationReport.Summary {
        switch self {
        case .firstSeen: .passed("firstSeen")
        case .consistent: .passed("consistent")
        case .rollback: .failed("rollback")
        case .inconsistent: .failed("inconsistent")
        case .unverifiable(let reason): .unverifiable(reason)
        }
    }
}

extension ResolverVerificationReport.Policy {
    var summary: ResolverVerificationReport.Summary {
        switch self {
        case .notPresent: .passed("notPresent")
        case .valid: .passed("valid")
        case .invalid(let reason): .invalid(reason)
        case .unverifiable(let reason): .unverifiable(reason)
        }
    }
}

extension ResolverVerificationReport.Placement {
    var summary: ResolverVerificationReport.Summary {
        switch self {
        case .match: .passed("match")
        case .mismatch: .failed("mismatch")
        case .indeterminate(let reason): .indeterminate(reason)
        case .unverifiable(let reason): .unverifiable(reason)
        }
    }
}

private extension ResolverVerificationReport.Overall {
    var code: String {
        switch self {
        case .verified: "verified"
        case .failed(let check): "failed(\(check.rawValue))"
        case .unverifiable(let check): "unverifiable(\(check.rawValue))"
        }
    }
}
