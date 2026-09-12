//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation

/// GUA FORK: a fixed-answer identity service for previews.
///
/// Screens that read the account's factor report otherwise have nothing to render in a preview: the
/// real client needs a session, fails without one, and the screen correctly renders "we could not
/// read your settings" instead of the thing being previewed.
@MainActor
final class IdentityServiceClientMock: IdentityServiceClientProtocol {
    var status: AccountSecurityStatus

    init(status: AccountSecurityStatus) {
        self.status = status
    }

    func securityStatus(accessToken: String) async throws -> AccountSecurityStatus {
        status
    }

    func lookupContacts(accessToken: String, phones: [String]) async throws -> [ContactMatch] {
        []
    }

    func startAccountReauth(accessToken: String, language: String?) async throws { }
    func verifyAccountReauth(accessToken: String, code: String, operation: ReauthOperation) async throws -> String {
        ""
    }

    func deactivateAccount(accessToken: String, reauthToken: String, eraseData: Bool) async throws { }
    func resetIdentityCredentials(accessToken: String, reauthToken: String) async throws -> IdentityResetCredentials {
        IdentityResetCredentials(userId: "", password: "")
    }

    func setInitialPin(accessToken: String, userId: String, newPin: String) async throws { }
    func startPinChange(accessToken: String, phone: String, currentPin: String) async throws -> String {
        ""
    }

    func completePinChange(accessToken: String, challengeId: String, otpCode: String, newPin: String) async throws { }
    func startPasskeyStepUp(accessToken: String) async throws -> PasskeyStepUpOptions {
        throw IdentityServiceError.passkeyStepUpUnavailable
    }

    func startPhoneChange(accessToken: String,
                          reauthToken: String,
                          newPhone: String,
                          pin: String?,
                          passkeyStepUpID: String?,
                          passkeyAssertion: PasskeyAssertion?,
                          language: String?) async throws -> PhoneChangeChallenge {
        PhoneChangeChallenge(challengeID: "", otpExpiresInSeconds: 0)
    }

    func completePhoneChange(accessToken: String, challengeId: String, code: String) async throws { }
    func startPasskeyEnrollment(accessToken: String) async throws -> URL {
        URL(string: "https://example.invalid")!
    }
}
