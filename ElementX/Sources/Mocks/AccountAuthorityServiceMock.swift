//
// Copyright 2026 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation

/// GUA FORK: a fixed-answer account authority service for previews.
///
/// The two authority screens read the chain, the candidates, the live approvals and the security-notification
/// rows the moment they appear. A preview with the real service has no session, so every one of those reads
/// fails and the screen correctly renders "we could not read this" instead of the thing being previewed.
///
/// Every value here is inert. No key is generated, nothing is signed, and the two `prepare` methods hand back
/// a record with a printable artifact rather than a real one: a preview must never mint the private recovery
/// authority key, and a screenshot of a real one would be a screenshot of a secret.
@MainActor
final class AccountAuthorityServiceMock: AccountAuthorityServiceProtocol {
    var isEnabled = true
    var chain: AuthorityChainState?
    var candidateList: [AuthorityCandidate] = []
    var approvals: [AuthorityApproval] = []
    var alerts: [SecurityNotificationSummary] = []
    var installationID: String?
    var deviceKey: String?
    /// An error for the reads, so the states a screen reaches by failing can be previewed too.
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
                              stepUp: AuthorityStepUp?) async throws { }

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

    /// A printable stand-in for the artifact, in the shape the encoding produces but not from any key.
    static let artifact = "gua-recovery-1 tvq3 dhpp 7vng boue jl2j f3bm yrce trlj pmzg sglq howa ghfo p5qa"

    /// A fixed preview accountId, built rather than derived so nothing on a preview's path can throw.
    /// Canonical by construction: the value is this client's own base32 of exactly these raw bytes.
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
