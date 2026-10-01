//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation

@MainActor
final class AccountAuthorityServiceMock: AccountAuthorityServiceProtocol {
    var isEnabled = true
    var chain: AuthorityChainState?
    var candidateList: [AuthorityCandidate] = []
    var approvals: [AuthorityApproval] = []
    var alerts: [SecurityNotificationSummary] = []
    var installationID: String?
    var deviceKey: String?
    var loadError: Error?

    init(chain: AuthorityChainState? = nil,
         candidateList: [AuthorityCandidate] = [],
         approvals: [AuthorityApproval] = [],
         alerts: [SecurityNotificationSummary] = [],
         installationID: String? = nil,
         deviceKey: String? = nil,
         loadError: Error? = nil) {
        self.chain = chain
        self.candidateList = candidateList
        self.approvals = approvals
        self.alerts = alerts
        self.installationID = installationID
        self.deviceKey = deviceKey
        self.loadError = loadError
    }

    func state(accessToken: String) async throws -> AuthorityChainState {
        if let loadError { throw loadError }
        guard let chain else { throw AccountAuthorityServiceError.disabled }
        return chain
    }

    func webStepUpURL(accessToken: String, purpose: AuthorityPurpose) async throws -> URL {
        URL(string: "https://auth.gua.test/login/step-up/preview")!
    }

    func prepareAdoption(accessToken: String,
                         accountID: AccountID,
                         stepUp: AuthorityStepUp) async throws -> PreparedAuthorityRecord {
        Self.prepared(kind: .adoption, accountID: accountID)
    }

    func prepareRecovery(accessToken: String,
                         state: AuthorityChainState,
                         typedArtifact: String,
                         stepUp: AuthorityStepUp) async throws -> PreparedAuthorityRecord {
        Self.prepared(kind: .recoveryUnderRecoveryKey, accountID: state.accountID)
    }

    func prepareRecoveryThroughAccountRecovery(accessToken: String,
                                               state: AuthorityChainState,
                                               stepUp: AuthorityStepUp) async throws -> PreparedAuthorityRecord {
        Self.prepared(kind: .recoveryThroughAccountRecovery, accountID: state.accountID)
    }

    func submit(accessToken: String, prepared: PreparedAuthorityRecord) async throws -> AuthoritySubmission {
        AuthoritySubmission(seq: 2,
                            isPending: true,
                            effectiveAt: Date(timeIntervalSince1970: 1_767_582_045),
                            recordHash: String(repeating: "ab", count: 32))
    }

    func offerThisDevice(accessToken: String, state: AuthorityChainState) async throws -> AuthorityCandidate {
        Self.candidate
    }

    func candidates(accessToken: String) async throws -> [AuthorityCandidate] {
        candidateList
    }

    func signDeviceGrant(accessToken: String,
                         state: AuthorityChainState,
                         candidate: AuthorityCandidate,
                         comparisonConfirmed: Bool,
                         stepUp: AuthorityStepUp) async throws -> AuthoritySubmission {
        try await submit(accessToken: accessToken, prepared: Self.prepared(kind: .adoption, accountID: state.accountID))
    }

    func revokeDevice(accessToken: String,
                      state: AuthorityChainState,
                      deviceKey: String,
                      reason: UInt8,
                      stepUp: AuthorityStepUp) async throws -> AuthoritySubmission {
        try await submit(accessToken: accessToken, prepared: Self.prepared(kind: .adoption, accountID: state.accountID))
    }

    func oppose(accessToken: String,
                state: AuthorityChainState,
                pending: AuthorityPendingTransition,
                stepUp: AuthorityStepUp?) async throws { }

    func registerSecurityAlerts(accessToken: String, accountID: AccountID) async throws -> SecurityNotificationSummary {
        guard let first = alerts.first else { throw AccountAuthorityServiceError.noPushToken }
        return first
    }

    func securityAlerts(accessToken: String) async throws -> [SecurityNotificationSummary] {
        if let loadError { throw loadError }
        return alerts
    }

    func removeSecurityAlerts(accessToken: String,
                              accountID: AccountID,
                              installationID: String,
                              stepUp: AuthorityStepUp) async throws { }

    func thisInstallationID() -> String? {
        installationID
    }

    func liveApprovals(accessToken: String) async throws -> [AuthorityApproval] {
        if let loadError { throw loadError }
        return approvals
    }

    func signApproval(accessToken: String, approval: AuthorityApproval, state: AuthorityChainState) async throws { }

    func thisDeviceKey(accountID: AccountID) -> String? {
        deviceKey
    }

    // MARK: - Fixed values

    /// A stand-in in the artifact's format, not derived from any key.
    static let artifact = "gua-recovery-1 tvq3 dhpp 7vng boue jl2j f3bm yrce trlj pmzg sglq howa ghfo p5qa"

    static let accountID: AccountID = {
        let raw = [AccountID.formatVersion, AccountID.classBootstrap] + [UInt8](repeating: 0x11, count: 32)
        return AccountID(value: AccountID.prefix + GuaBase32.encode(raw), rawBytes: raw)
    }()

    static let candidate = AuthorityCandidate(deviceKeyB64: "a-candidate-key",
                                              fingerprint: "K7RM2XQ4",
                                              label: "iPad",
                                              expiresAt: Date(timeIntervalSince1970: 1_767_323_445))

    private static func prepared(kind: PreparedAuthorityRecord.Kind, accountID: AccountID) -> PreparedAuthorityRecord {
        PreparedAuthorityRecord(kind: kind,
                                accountID: accountID,
                                record: "cmVjb3Jk",
                                signature: "c2lnbmF0dXJl",
                                challenge: "Y2hhbGxlbmdl",
                                deviceLabel: "iPhone",
                                recoveryArtifact: artifact)
    }
}
