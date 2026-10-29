//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// The outcome of one report-only verification of a `/resolve` answer. Every field is an outcome code, the
/// roster version and form, or the environment label: never the phone, the answer or a hostname, because the
/// report is logged and log files travel in bug reports.
struct ResolverVerificationReport: Equatable {
    enum RosterSignature: Equatable {
        case valid
        case invalid(reason: String)
        case unverifiable(reason: String)
    }

    enum HomeserverMatch: Equatable {
        case activeMatch
        case inactive
        case fieldMismatch
        case notInRoster
        case unverifiable
    }

    enum MemberEntry: Equatable {
        case valid
        case unattested
        case invalid(reason: String)
        case unverifiable
    }

    enum LogConsistency: Equatable {
        case consistent
        case firstSeen
        case rollback
        case inconsistent
        case unverifiable(reason: String)
    }

    enum Policy: Equatable {
        case notPresent
        case valid
        case invalid(reason: String)
        case unverifiable(reason: String)
    }

    enum Placement: Equatable {
        case match
        case mismatch
        case indeterminate
        case unverifiable(reason: String)
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

    /// `verified` when every applicable check passed, `failed` on the first check that found an input wrong,
    /// otherwise `unverifiable` on the first check that could not run. An `indeterminate` placement (a
    /// directory hit, which cannot be reproduced) counts as unverifiable, never as verified.
    var overall: Overall {
        let verdicts: [(Check, Verdict)] = [(.rosterSignature, rosterSignature.verdict),
                                            (.homeserverMatch, homeserverMatch.verdict),
                                            (.memberEntry, memberEntry.verdict),
                                            (.logConsistency, logConsistency.verdict),
                                            (.policy, policy.verdict),
                                            (.placement, placement.verdict)]
        if let failed = verdicts.first(where: { $0.1 == .failed }) { return .failed(failed.0) }
        if let unverifiable = verdicts.first(where: { $0.1 == .unverifiable }) { return .unverifiable(unverifiable.0) }
        return .verified
    }

    /// The report as one log line of codes.
    var logDescription: String {
        ["environment=\(environment)",
         "rosterVersion=\(rosterVersion.map { String($0) } ?? "none")",
         "rosterForm=\(rosterForm ?? "none")",
         "rosterSignature=\(rosterSignature.code)",
         "homeserverMatch=\(homeserverMatch.code)",
         "memberEntry=\(memberEntry.code)",
         "logConsistency=\(logConsistency.code)",
         "policy=\(policy.code)",
         "placement=\(placement.code)",
         "overall=\(overall.code)",
         "durationMs=\(durationMs)"].joined(separator: " ")
    }

    fileprivate enum Verdict {
        case passed, failed, unverifiable
    }
}

private extension ResolverVerificationReport.RosterSignature {
    var verdict: ResolverVerificationReport.Verdict {
        switch self {
        case .valid: .passed
        case .invalid: .failed
        case .unverifiable: .unverifiable
        }
    }

    var code: String {
        switch self {
        case .valid: "valid"
        case .invalid(let reason): "invalid:\(reason)"
        case .unverifiable(let reason): "unverifiable:\(reason)"
        }
    }
}

private extension ResolverVerificationReport.HomeserverMatch {
    var verdict: ResolverVerificationReport.Verdict {
        switch self {
        case .activeMatch: .passed
        case .inactive, .fieldMismatch, .notInRoster: .failed
        case .unverifiable: .unverifiable
        }
    }

    var code: String {
        switch self {
        case .activeMatch: "ACTIVE_MATCH"
        case .inactive: "INACTIVE"
        case .fieldMismatch: "FIELD_MISMATCH"
        case .notInRoster: "NOT_IN_ROSTER"
        case .unverifiable: "unverifiable"
        }
    }
}

private extension ResolverVerificationReport.MemberEntry {
    var verdict: ResolverVerificationReport.Verdict {
        switch self {
        case .valid, .unattested: .passed
        case .invalid: .failed
        case .unverifiable: .unverifiable
        }
    }

    var code: String {
        switch self {
        case .valid: "valid"
        case .unattested: "unattested"
        case .invalid(let reason): "invalid:\(reason)"
        case .unverifiable: "unverifiable"
        }
    }
}

private extension ResolverVerificationReport.LogConsistency {
    var verdict: ResolverVerificationReport.Verdict {
        switch self {
        case .consistent, .firstSeen: .passed
        case .rollback, .inconsistent: .failed
        case .unverifiable: .unverifiable
        }
    }

    var code: String {
        switch self {
        case .consistent: "consistent"
        case .firstSeen: "firstSeen"
        case .rollback: "rollback"
        case .inconsistent: "inconsistent"
        case .unverifiable(let reason): "unverifiable:\(reason)"
        }
    }
}

private extension ResolverVerificationReport.Policy {
    var verdict: ResolverVerificationReport.Verdict {
        switch self {
        case .notPresent, .valid: .passed
        case .invalid: .failed
        case .unverifiable: .unverifiable
        }
    }

    var code: String {
        switch self {
        case .notPresent: "notPresent"
        case .valid: "valid"
        case .invalid(let reason): "invalid:\(reason)"
        case .unverifiable(let reason): "unverifiable:\(reason)"
        }
    }
}

private extension ResolverVerificationReport.Placement {
    var verdict: ResolverVerificationReport.Verdict {
        switch self {
        case .match: .passed
        case .mismatch: .failed
        case .indeterminate, .unverifiable: .unverifiable
        }
    }

    var code: String {
        switch self {
        case .match: "match"
        case .mismatch: "mismatch"
        case .indeterminate: "indeterminate"
        case .unverifiable(let reason): "unverifiable:\(reason)"
        }
    }
}

private extension ResolverVerificationReport.Overall {
    var code: String {
        switch self {
        case .verified: "verified"
        case .failed(let check): "failed:\(check.rawValue)"
        case .unverifiable(let check): "unverifiable:\(check.rawValue)"
        }
    }
}
