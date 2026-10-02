//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation

enum IdentityServiceError: Error, LocalizedError {
    case notConfigured
    case invalidURL
    case rateLimited
    case invalidOTP
    case invalidPin
    case pinLocked(retryAfterSeconds: Int?)
    case pinChangeCooldown(retryAfterSeconds: Int?)
    case pinChangeChallengeInvalid
    /// The phone-change challenge from `/account/phone/change/start` is missing or expired, so the
    /// flow has to start again from the reauth step.
    case phoneChangeChallengeInvalid
    /// 403 `step_up_required`: the account holds neither a PIN nor a passkey and the operation demands
    /// one. A hard block, not a prompt to retry: nothing proceeds until a factor is set up.
    case stepUpRequired
    /// Passkeys are off on this deployment or the account has no credential to assert. Callers fall
    /// back to the next factor.
    case passkeyStepUpUnavailable
    /// 403 `passkey_user_verification_required`: the assertion proved possession of the device but
    /// did not verify the user.
    case passkeyUserVerificationRequired
    /// The factor being used was registered too recently. Covers a new PIN and a new passkey alike.
    case twoFactorCooldown(retryAfterSeconds: Int?)
    /// 425 `phone_change_cooldown`: the minimum gap between two phone changes. Independent of
    /// `twoFactorCooldown`; waiting out one does not clear the other.
    case phoneChangeCooldown(retryAfterSeconds: Int?)
    case invalidReauthToken
    case phoneAlreadyLinked
    /// 403 `reauth_phone_mismatch`: the number typed at a reauth step is not the one on the signed-in
    /// account. Shown with one neutral string, so it never reveals whether the number belongs to
    /// another account.
    case reauthPhoneMismatch
    /// 400 `invalid_phone_number`: the number could not be parsed. Says nothing about which account
    /// it belongs to.
    case invalidPhoneNumber
    /// 409 `pin_already_set`: the account gained a PIN since the factor report was read, so there is
    /// nothing to enroll.
    case pinAlreadySet
    /// 409 `passkey_already_registered`: the same as `pinAlreadySet`, for a passkey.
    case passkeyAlreadyRegistered
    /// 409 `step_up_unavailable`: the account's only factor is a passkey and this deployment has
    /// passkeys off. The only way back into the account is the delayed recovery.
    case stepUpUnavailable
    /// 400 `invalid_redirect_uri`: the deployment's allowlist does not permit the redirect this build
    /// asked for. The client retries without a redirect, so this surfaces only if that also fails.
    case invalidRedirectURI
    /// `POST /account/genesis` answered 503: this deployment does not do account genesis. Callers
    /// carry on with the existing signup; it is not a failure.
    case genesisUnavailable
    /// `POST /account/genesis` answered 403: the deployment declines to issue a handle under this
    /// client's recovery framework. Like 503, no handle exists and the signup continues without one.
    case genesisIssuanceNotPermitted
    case server(status: Int, message: String?)
    case transport(Error)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Identity service is not configured."
        case .invalidURL: "Identity service URL is invalid."
        case .rateLimited: "Too many attempts. Please wait a moment and try again."
        case .invalidOTP: "The code you entered is invalid or has expired."
        case .invalidPin: "That PIN is incorrect. Please try again."
        case let .pinLocked(retry):
            if let retry { "PIN locked due to too many wrong attempts. Try again in \(retry / 60) minute(s)." }
            else { "PIN locked due to too many wrong attempts. Try again later." }
        case let .pinChangeCooldown(retry):
            if let retry, retry > 0 {
                "For security, you can change your PIN again in \(max(1, Int((Double(retry) / 3600.0).rounded(.up)))) hour(s)."
            } else { "For security, you can only change your PIN once per day." }
        case .pinChangeChallengeInvalid: "Your PIN change session expired. Please start over."
        case .phoneChangeChallengeInvalid: "Your number change expired. Please start over."
        case .stepUpRequired: "You'll need two-step verification before you can change your number."
        case .passkeyStepUpUnavailable: "Your passkey can't be used for this right now."
        case .passkeyUserVerificationRequired: "That passkey didn't verify it was you. Please try again."
        case let .twoFactorCooldown(retry):
            if let retry, retry > 0 {
                "For your security, you can change your number in \(IdentityServiceError.humanReadableDuration(seconds: retry))."
            } else { "For your security, you can't change your number just yet. Please try again later." }
        case let .phoneChangeCooldown(retry):
            if let retry, retry > 0 {
                "For your security, you can change your number again in \(IdentityServiceError.humanReadableDuration(seconds: retry))."
            } else { "For your security, you can't change your number again just yet. Please try again later." }
        case .invalidReauthToken: "Your verification expired. Please request a new code."
        case .phoneAlreadyLinked: "That phone number is already linked to another account."
        case .reauthPhoneMismatch: L10n.screenAccountReauthPhoneMismatch
        case .invalidPhoneNumber: L10n.screenPhoneLoginInvalidNumber
        case .pinAlreadySet: L10n.screenTwoStepVerificationPinAlreadySet
        case .passkeyAlreadyRegistered: L10n.screenTwoStepVerificationPasskeyAlreadySet
        case .stepUpUnavailable: L10n.screenTwoStepVerificationStepUpUnavailable
        case .invalidRedirectURI: L10n.errorUnknown
        case .genesisUnavailable: "Account genesis is not enabled on this deployment."
        case .genesisIssuanceNotPermitted: "Account genesis issuance is not permitted on this deployment."
        case let .server(status, message): message ?? "Server error (\(status))."
        case let .transport(error): error.localizedDescription
        case let .decoding(error): "Could not parse the server response: \(error.localizedDescription)"
        }
    }

    /// Coarse rendering of a remaining duration, e.g. "7 days", "3 hours", "5 minutes". Rounds up, so
    /// the wait shown is never shorter than the real one.
    static func humanReadableDuration(seconds: Int) -> String {
        let seconds = max(0, seconds)
        let day = 86400, hour = 3600, minute = 60
        if seconds >= day {
            let days = Int((Double(seconds) / Double(day)).rounded(.up))
            return days == 1 ? L10n.commonDurationOneDay : L10n.commonDurationDays(days)
        }
        if seconds >= hour {
            let hours = Int((Double(seconds) / Double(hour)).rounded(.up))
            return hours == 1 ? L10n.commonDurationOneHour : L10n.commonDurationHours(hours)
        }
        let minutes = max(1, Int((Double(seconds) / Double(minute)).rounded(.up)))
        return minutes == 1 ? L10n.commonDurationOneMinute : L10n.commonDurationMinutes(minutes)
    }
}

/// What `POST /account/genesis` returns. The handle is single-use and expires at `expiresAt`; the
/// server stores only its hash.
struct AccountGenesisRegistrationResponse: Equatable {
    let accountID: String
    let attachHandle: String
    let expiresAt: Date
}

@MainActor
protocol IdentityServiceClientProtocol {
    /// Contact discovery: match a batch of address-book phone numbers (E.164) against Gua
    /// accounts. The numbers are sent over TLS and digested server-side; only the contacts
    /// that are on Gua and discoverable come back.
    func lookupContacts(accessToken: String, phones: [String]) async throws -> [ContactMatch]
    /// Sends the reauth OTP, but only when `phone` is the number on the caller's own account. The
    /// number is a proof, not a routing hint: a number that is not this account's is refused the same
    /// way whoever it belongs to.
    func startAccountReauth(accessToken: String, phone: String, language: String?) async throws
    /// Exchanges the reauth OTP for a single-use token scoped to `operation`. The server refuses the
    /// token for any other operation.
    func verifyAccountReauth(accessToken: String, phone: String, code: String, operation: ReauthOperation) async throws -> String
    func deactivateAccount(accessToken: String, reauthToken: String, eraseData: Bool) async throws
    func resetIdentityCredentials(accessToken: String, reauthToken: String) async throws -> IdentityResetCredentials
    /// `GET /security/pin/status`. Reports the whole factor inventory, not just the PIN; every "which
    /// factor does this account need" decision reads it.
    func securityStatus(accessToken: String) async throws -> AccountSecurityStatus
    /// Starts a PIN change and texts a code to `phone`. Authorized by the passkey assertion when
    /// `passkeyStepUpID` and `passkeyAssertion` are supplied, otherwise by `currentPin`.
    func startPinChange(accessToken: String,
                        phone: String,
                        currentPin: String?,
                        passkeyStepUpID: String?,
                        passkeyAssertion: PasskeyAssertion?) async throws -> String
    func completePinChange(accessToken: String, challengeId: String, otpCode: String, newPin: String) async throws
    /// Cancels a delayed account recovery on the signed-in account (`POST /security/recovery/cancel`).
    /// The server answers 204 whether or not one was pending, so success says nothing about what was
    /// there; read `securityStatus` again for that.
    func cancelAccountRecovery(accessToken: String) async throws
    // Change phone number: reauth by OTP to the current number first (`/account/reauth/start` and
    // `/account/reauth/verify` scoped to PHONE_CHANGE), then `/account/phone/change/start`, which
    // spends that token with a step-up factor and only then texts the new number, and finally
    // `/account/phone/change/complete` with the code that arrived there.
    func startPasskeyStepUp(accessToken: String) async throws -> PasskeyStepUpOptions
    func startPhoneChange(accessToken: String,
                          reauthToken: String,
                          newPhone: String,
                          pin: String?,
                          passkeyStepUpID: String?,
                          passkeyAssertion: PasskeyAssertion?,
                          language: String?) async throws -> PhoneChangeChallenge
    func completePhoneChange(accessToken: String, challengeId: String, code: String) async throws
    /// Begins passkey enrollment and returns the IdP-hosted URL to load in an authenticated web
    /// session. The flow finishes when that page redirects to the app's OIDC redirect URL.
    ///
    /// `redirectURI` is this build's own redirect, so the sheet returns to the variant it was opened
    /// from. It is a request: the server keeps the allowlist and the client falls back to the
    /// deployment's default when it refuses.
    func startPasskeyEnrollment(accessToken: String, redirectURI: String?) async throws -> URL
    /// Begins PIN enrollment the same way. A bearer session alone must not add a factor, so the first
    /// PIN is set in a web session that confirms the account. Changing an existing PIN stays native.
    func startPinEnrollment(accessToken: String, redirectURI: String?) async throws -> URL
}

/// The slice of identity-service that account genesis needs. Separate from
/// `IdentityServiceClientProtocol` because this call is unauthenticated and runs before any
/// session exists.
protocol AccountGenesisRegistering: Sendable {
    /// Registers an on-device `AccountGenesis` and returns its accountId with a single-use attach
    /// handle. Self-authenticating: the body carries a possession proof under the key committed inside
    /// the genesis itself.
    ///
    /// Both arguments are base64url without padding. Throws ``IdentityServiceError/genesisUnavailable``
    /// on 503 and ``IdentityServiceError/genesisIssuanceNotPermitted`` on 403. Both mean the deployment
    /// issues no handle, not that anything went wrong.
    func registerAccountGenesis(genesis: String, proof: String) async throws -> AccountGenesisRegistrationResponse
}

/// Ephemeral credentials for the `m.login.password` UIA stage of an identity reset.
struct IdentityResetCredentials: Equatable {
    let userId: String
    let password: String
}

/// A contact-discovery hit: an address-book phone number that belongs to a Gua account.
/// `phoneNumber` echoes back the submitted number so the client can map it onto the local
/// address book; `username` is the global Gua handle when one has been assigned.
struct ContactMatch: Equatable, Identifiable {
    let phoneNumber: String
    let userId: String
    let username: String?
    let displayName: String?

    var id: String {
        userId
    }
}

final class IdentityServiceClient: IdentityServiceClientProtocol, AccountGenesisRegistering {
    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
        decoder = JSONDecoder()
        encoder = JSONEncoder()
    }

    convenience init?() {
        guard let url = GuaDeployment.current.identityServiceBaseURL else { return nil }
        self.init(baseURL: url)
    }

    // MARK: - Contact discovery

    func lookupContacts(accessToken: String, phones: [String]) async throws -> [ContactMatch] {
        struct Body: Encodable { let phones: [String] }
        struct Response: Decodable {
            struct Match: Decodable {
                let phone: String
                let userId: String
                let username: String?
                let displayName: String?
            }

            let matches: [Match]
        }
        let (data, _) = try await sendAuthenticated(path: "/directory/lookup",
                                                    accessToken: accessToken,
                                                    body: Body(phones: phones),
                                                    language: nil,
                                                    expectsBody: true)
        do {
            let response = try decoder.decode(Response.self, from: data)
            return response.matches.map {
                ContactMatch(phoneNumber: $0.phone, userId: $0.userId, username: $0.username, displayName: $0.displayName)
            }
        } catch {
            throw IdentityServiceError.decoding(error)
        }
    }

    // MARK: - Account reauthentication

    func startAccountReauth(accessToken: String, phone: String, language: String?) async throws {
        struct Body: Encodable { let phone: String }
        try await sendAuthenticated(path: "/account/reauth/start",
                                    accessToken: accessToken,
                                    body: Body(phone: phone),
                                    language: language,
                                    expectsBody: false)
    }

    func verifyAccountReauth(accessToken: String, phone: String, code: String, operation: ReauthOperation) async throws -> String {
        struct Body: Encodable { let phone: String; let code: String; let operation: String }
        struct Response: Decodable { let reauthToken: String; let expiresInSeconds: Int }
        let (data, _) = try await sendAuthenticated(path: "/account/reauth/verify",
                                                    accessToken: accessToken,
                                                    body: Body(phone: phone, code: code, operation: operation.rawValue),
                                                    language: nil,
                                                    expectsBody: true)
        do {
            return try decoder.decode(Response.self, from: data).reauthToken
        } catch {
            throw IdentityServiceError.decoding(error)
        }
    }

    func deactivateAccount(accessToken: String, reauthToken: String, eraseData: Bool) async throws {
        struct Body: Encodable { let reauthToken: String; let eraseData: Bool }
        try await sendAuthenticated(path: "/account/deactivate",
                                    accessToken: accessToken,
                                    body: Body(reauthToken: reauthToken, eraseData: eraseData),
                                    language: nil,
                                    expectsBody: false)
    }

    func resetIdentityCredentials(accessToken: String, reauthToken: String) async throws -> IdentityResetCredentials {
        struct Body: Encodable { let reauthToken: String }
        struct Response: Decodable { let userId: String; let password: String }
        let (data, _) = try await sendAuthenticated(path: "/account/reset-identity-credentials",
                                                    accessToken: accessToken,
                                                    body: Body(reauthToken: reauthToken),
                                                    language: nil,
                                                    expectsBody: true)
        do {
            let resp = try decoder.decode(Response.self, from: data)
            return IdentityResetCredentials(userId: resp.userId, password: resp.password)
        } catch {
            throw IdentityServiceError.decoding(error)
        }
    }

    // MARK: - Two-step verification (PIN)

    func securityStatus(accessToken: String) async throws -> AccountSecurityStatus {
        struct Response: Decodable {
            let hasPin: Bool
            let changePhoneCooldownRemainingSeconds: Int?
            let passkeyRegistered: Bool?
            let preferredFactor: String?
            let phoneChangeStepUpFactors: [String]?
            let accountRecoveryPending: Bool?
            let accountRecoveryCompletableAtEpochSeconds: Int64?
            let accountRecoveryExpiresAtEpochSeconds: Int64?
        }
        guard let url = URL(string: "/security/pin/status", relativeTo: baseURL) else {
            throw IdentityServiceError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw IdentityServiceError.transport(error)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw IdentityServiceError.server(status: -1, message: "Non-HTTP response.")
        }
        guard httpResponse.statusCode == 200 else {
            let message = (try? decoder.decode(ErrorBody.self, from: data)).flatMap { $0.message ?? $0.error }
            throw IdentityServiceError.server(status: httpResponse.statusCode, message: message)
        }
        do {
            let response = try decoder.decode(Response.self, from: data)
            // A field the deployment did not send stays absent rather than becoming a value: a hold
            // defaulted to 0 would read as "no hold", while `nil` says "not reported".
            return AccountSecurityStatus(hasPin: response.hasPin,
                                         passkeyRegistered: response.passkeyRegistered ?? false,
                                         preferredFactor: response.preferredFactor.map(AuthFactor.init(wireValue:)),
                                         phoneChangeStepUpFactors: (response.phoneChangeStepUpFactors ?? []).map(AuthFactor.init(wireValue:)),
                                         pinStepUpHoldRemainingSeconds: response.changePhoneCooldownRemainingSeconds.map { max(0, $0) },
                                         pendingAccountRecovery: Self.pendingAccountRecovery(pending: response.accountRecoveryPending,
                                                                                             completableAt: response.accountRecoveryCompletableAtEpochSeconds,
                                                                                             expiresAt: response.accountRecoveryExpiresAtEpochSeconds))
        } catch {
            throw IdentityServiceError.decoding(error)
        }
    }

    /// An older deployment sends none of the recovery fields, which reads as nothing pending. The
    /// dates only mean something while a recovery is live, so they are dropped when it is not.
    private static func pendingAccountRecovery(pending: Bool?, completableAt: Int64?, expiresAt: Int64?) -> PendingAccountRecovery? {
        guard pending == true else { return nil }
        return PendingAccountRecovery(completableAt: completableAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                                      expiresAt: expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) })
    }

    func startPinChange(accessToken: String,
                        phone: String,
                        currentPin: String?,
                        passkeyStepUpID: String?,
                        passkeyAssertion: PasskeyAssertion?) async throws -> String {
        struct Body: Encodable {
            let phone: String
            let currentPin: String?
            let passkeyStepUpId: String?
            let passkeyCredential: PasskeyAssertion?
        }
        struct Response: Decodable {
            let challengeId: String
            let expiresInSeconds: Int?
        }
        let (data, _) = try await sendAuthenticated(path: "/security/pin/change/start",
                                                    accessToken: accessToken,
                                                    body: Body(phone: phone,
                                                               currentPin: currentPin,
                                                               passkeyStepUpId: passkeyStepUpID,
                                                               passkeyCredential: passkeyAssertion),
                                                    language: nil,
                                                    expectsBody: true)
        do {
            return try decoder.decode(Response.self, from: data).challengeId
        } catch {
            throw IdentityServiceError.decoding(error)
        }
    }

    func completePinChange(accessToken: String, challengeId: String, otpCode: String, newPin: String) async throws {
        struct Body: Encodable {
            let challengeId: String
            let otpCode: String
            let newPin: String
        }
        try await sendAuthenticated(path: "/security/pin/change/complete",
                                    accessToken: accessToken,
                                    body: Body(challengeId: challengeId, otpCode: otpCode, newPin: newPin),
                                    language: nil,
                                    expectsBody: false)
    }

    // MARK: - Account recovery

    func cancelAccountRecovery(accessToken: String) async throws {
        struct EmptyBody: Encodable { }
        try await sendAuthenticated(path: "/security/recovery/cancel",
                                    accessToken: accessToken,
                                    body: EmptyBody(),
                                    language: nil,
                                    expectsBody: false)
    }

    // MARK: - Change phone number

    /// Requests a user-verifying passkey ceremony pinned to the authenticated caller
    /// (`POST /security/passkey/stepup/options`).
    ///
    /// A deployment with passkeys off answers 404 and an account with no registered credential
    /// answers 409; both surface as ``IdentityServiceError/passkeyStepUpUnavailable`` so the caller
    /// offers the next factor instead of treating it as a failure.
    func startPasskeyStepUp(accessToken: String) async throws -> PasskeyStepUpOptions {
        struct EmptyBody: Encodable { }
        struct Response: Decodable {
            let stepUpId: String
            let publicKey: PublicKey

            struct PublicKey: Decodable {
                let challenge: String
                let rpId: String?
                let allowCredentials: [Descriptor]?

                struct Descriptor: Decodable {
                    let id: String
                }
            }
        }
        let (data, _) = try await sendAuthenticated(path: "/security/passkey/stepup/options",
                                                    accessToken: accessToken,
                                                    body: EmptyBody(),
                                                    language: nil,
                                                    expectsBody: true)
        let response: Response
        do {
            response = try decoder.decode(Response.self, from: data)
        } catch {
            throw IdentityServiceError.decoding(error)
        }
        // Every byte field on the wire is base64url. A ceremony that cannot be assembled verbatim
        // becomes "unavailable" and the caller asks for the PIN.
        guard let relyingPartyID = response.publicKey.rpId, !relyingPartyID.isEmpty,
              let challenge = GuaBase64URL.decode(response.publicKey.challenge).map({ Data($0) }) else {
            throw IdentityServiceError.passkeyStepUpUnavailable
        }
        let allowed = (response.publicKey.allowCredentials ?? [])
            .compactMap { GuaBase64URL.decode($0.id).map { Data($0) } }
        return PasskeyStepUpOptions(stepUpID: response.stepUpId,
                                    relyingPartyID: relyingPartyID,
                                    challenge: challenge,
                                    allowedCredentialIDs: allowed)
    }

    /// Starts the change (`POST /account/phone/change/start`): spends the PHONE_CHANGE-scoped reauth
    /// token together with the step-up factor and returns the challenge to redeem. No SMS reaches the
    /// new number until the server has accepted a step-up.
    ///
    /// Sends exactly one step-up: the passkey assertion when present, otherwise the PIN.
    func startPhoneChange(accessToken: String,
                          reauthToken: String,
                          newPhone: String,
                          pin: String?,
                          passkeyStepUpID: String?,
                          passkeyAssertion: PasskeyAssertion?,
                          language: String?) async throws -> PhoneChangeChallenge {
        struct Body: Encodable {
            let reauthToken: String
            let newPhone: String
            let pin: String?
            let passkeyStepUpId: String?
            let passkeyCredential: PasskeyAssertion?
        }
        struct Response: Decodable {
            let challengeId: String
            let otpExpiresInSeconds: Int?
        }
        let body = Body(reauthToken: reauthToken,
                        newPhone: newPhone,
                        pin: pin,
                        passkeyStepUpId: passkeyAssertion == nil ? nil : passkeyStepUpID,
                        passkeyCredential: passkeyAssertion)
        let (data, _) = try await sendAuthenticated(path: "/account/phone/change/start",
                                                    accessToken: accessToken,
                                                    body: body,
                                                    language: language,
                                                    expectsBody: true)
        do {
            let response = try decoder.decode(Response.self, from: data)
            return PhoneChangeChallenge(challengeID: response.challengeId,
                                        otpExpiresInSeconds: response.otpExpiresInSeconds ?? 0)
        } catch {
            throw IdentityServiceError.decoding(error)
        }
    }

    /// Redeems the challenge with the OTP delivered to the new number
    /// (`POST /account/phone/change/complete`). The server swaps the mapping atomically and revokes
    /// the outstanding sessions. 204 on success.
    func completePhoneChange(accessToken: String, challengeId: String, code: String) async throws {
        struct Body: Encodable {
            let challengeId: String
            let code: String
        }
        try await sendAuthenticated(path: "/account/phone/change/complete",
                                    accessToken: accessToken,
                                    body: Body(challengeId: challengeId, code: code),
                                    language: nil,
                                    expectsBody: false)
    }

    // MARK: - Factor enrollment

    func startPasskeyEnrollment(accessToken: String, redirectURI: String?) async throws -> URL {
        try await startFactorEnrollment(path: "/security/passkey/enroll/start",
                                        accessToken: accessToken,
                                        redirectURI: redirectURI)
    }

    func startPinEnrollment(accessToken: String, redirectURI: String?) async throws -> URL {
        try await startFactorEnrollment(path: "/security/pin/enroll/start",
                                        accessToken: accessToken,
                                        redirectURI: redirectURI)
    }

    /// Both enrollments return a one-time URL on the sign-in origin, opened in an authenticated web
    /// view. If the deployment refuses this build's redirect (`invalid_redirect_uri`), retries once
    /// without one so enrollment still runs and the sheet returns to the deployment's default app.
    private func startFactorEnrollment(path: String, accessToken: String, redirectURI: String?) async throws -> URL {
        do {
            return try await requestEnrollmentURL(path: path, accessToken: accessToken, redirectURI: redirectURI)
        } catch IdentityServiceError.invalidRedirectURI where redirectURI != nil {
            MXLog.warning("Enrollment redirect refused by the deployment, asking again for its default")
            return try await requestEnrollmentURL(path: path, accessToken: accessToken, redirectURI: nil)
        }
    }

    private func requestEnrollmentURL(path: String, accessToken: String, redirectURI: String?) async throws -> URL {
        struct Body: Encodable { let redirectUri: String? }
        struct Response: Decodable { let enrollUrl: String }
        let (data, _) = try await sendAuthenticated(path: path,
                                                    accessToken: accessToken,
                                                    body: Body(redirectUri: redirectURI),
                                                    language: Locale.guaLanguageTag(),
                                                    expectsBody: true)
        do {
            let response = try decoder.decode(Response.self, from: data)
            guard let url = URL(string: response.enrollUrl) else {
                throw IdentityServiceError.invalidURL
            }
            return url
        } catch let error as IdentityServiceError {
            throw error
        } catch {
            throw IdentityServiceError.decoding(error)
        }
    }

    // MARK: - Account genesis

    func registerAccountGenesis(genesis: String, proof: String) async throws -> AccountGenesisRegistrationResponse {
        struct Body: Encodable {
            let genesis: String
            let proof: String
        }
        struct Response: Decodable {
            let accountId: String
            let attachHandle: String
            let expiresAt: Date
        }

        guard let url = URL(string: "/account/genesis", relativeTo: baseURL) else {
            throw IdentityServiceError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            request.httpBody = try encoder.encode(Body(genesis: genesis, proof: proof))
        } catch {
            throw IdentityServiceError.transport(error)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw IdentityServiceError.transport(error)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw IdentityServiceError.server(status: -1, message: "Non-HTTP response.")
        }
        // 503 and 403 mean no handle exists to present; neither is a failure. Any other status that
        // is not 201 is, and the caller must not create an account without a handle.
        guard httpResponse.statusCode != 503 else { throw IdentityServiceError.genesisUnavailable }
        guard httpResponse.statusCode != 403 else { throw IdentityServiceError.genesisIssuanceNotPermitted }
        guard httpResponse.statusCode == 201 else {
            let errorBody = try? decoder.decode(ErrorBody.self, from: data)
            throw IdentityServiceError.server(status: httpResponse.statusCode,
                                              message: errorBody?.message ?? errorBody?.error)
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let parsed = try decoder.decode(Response.self, from: data)
            return AccountGenesisRegistrationResponse(accountID: parsed.accountId,
                                                      attachHandle: parsed.attachHandle,
                                                      expiresAt: parsed.expiresAt)
        } catch {
            throw IdentityServiceError.decoding(error)
        }
    }

    @discardableResult
    private func sendAuthenticated(path: String,
                                   accessToken: String,
                                   body: some Encodable,
                                   language: String?,
                                   expectsBody: Bool) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw IdentityServiceError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let language { request.setValue(language, forHTTPHeaderField: "Accept-Language") }
        do {
            request.httpBody = try encoder.encode(body)
        } catch {
            throw IdentityServiceError.transport(error)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw IdentityServiceError.transport(error)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw IdentityServiceError.server(status: -1, message: "Non-HTTP response.")
        }

        switch httpResponse.statusCode {
        case 200, 202, 204:
            return (data, httpResponse)
        default:
            throw Self.mappedError(status: httpResponse.statusCode,
                                   body: try? decoder.decode(ErrorBody.self, from: data),
                                   retryAfterHeader: httpResponse.value(forHTTPHeaderField: "Retry-After"),
                                   path: path)
        }
    }

    /// Turns a refusal into the typed error the screens branch on. Maps by error code, not status:
    /// 403 carries both the hard block and a passkey that did not verify its user, and 425 carries two
    /// cooldowns. An unrecognized code stays a plain server error.
    private static func mappedError(status: Int, body: ErrorBody?, retryAfterHeader: String?, path: String) -> IdentityServiceError {
        let retry = body?.retryAfterSeconds ?? retryAfterHeader.flatMap(Int.init)
        if let mapped = passkeyError(code: body?.code, status: status, path: path)
            ?? waitError(code: body?.code, retryAfterSeconds: retry)
            ?? credentialError(code: body?.code) {
            return mapped
        }
        if status == 429 {
            return .rateLimited
        }
        return .server(status: status, message: body?.message ?? body?.errorDescription ?? body?.error)
    }

    /// Everything that means the passkey path is not available right now. All of it falls back to
    /// the next factor instead of ending the operation.
    private static func passkeyError(code: String?, status: Int, path: String) -> IdentityServiceError? {
        switch code {
        case "passkey_user_verification_required": return .passkeyUserVerificationRequired
        case "passkey_authentication_failed", "passkey_unavailable", "passkey_not_registered",
             "passkey_user_unknown", "passkey_challenge_expired", "passkey_response_invalid":
            return .passkeyStepUpUnavailable
        default:
            // A passkey endpoint that is simply not there on this deployment.
            return status == 404 && path.hasPrefix("/security/passkey/") ? .passkeyStepUpUnavailable : nil
        }
    }

    /// The refusals that expire on their own. Waiting out one does nothing for the others.
    private static func waitError(code: String?, retryAfterSeconds: Int?) -> IdentityServiceError? {
        switch code {
        case "twofa_cooldown_active": .twoFactorCooldown(retryAfterSeconds: retryAfterSeconds)
        case "pin_change_cooldown": .pinChangeCooldown(retryAfterSeconds: retryAfterSeconds)
        case "phone_change_cooldown": .phoneChangeCooldown(retryAfterSeconds: retryAfterSeconds)
        case "pin_locked": .pinLocked(retryAfterSeconds: retryAfterSeconds)
        default: nil
        }
    }

    /// Wrong, missing or spent proofs, and the one refusal that ends the operation outright.
    /// The mismatch drops the server's message, a fixed English sentence, for the localized string.
    private static func credentialError(code: String?) -> IdentityServiceError? {
        switch code {
        case "invalid_otp": .invalidOTP
        case "invalid_pin": .invalidPin
        case "invalid_reauth_token": .invalidReauthToken
        case "pin_change_challenge_invalid": .pinChangeChallengeInvalid
        case "phone_change_challenge_invalid": .phoneChangeChallengeInvalid
        case "phone_already_linked": .phoneAlreadyLinked
        case "step_up_required": .stepUpRequired
        case "reauth_phone_mismatch": .reauthPhoneMismatch
        case "invalid_phone_number": .invalidPhoneNumber
        case "pin_already_set": .pinAlreadySet
        case "passkey_already_registered": .passkeyAlreadyRegistered
        case "step_up_unavailable": .stepUpUnavailable
        case "invalid_redirect_uri": .invalidRedirectURI
        default: nil
        }
    }

    // MARK: - Private

    private struct ErrorBody: Decodable {
        let code: String?
        let message: String?
        let error: String?
        let errorDescription: String?
        let retryAfterSeconds: Int?

        enum CodingKeys: String, CodingKey {
            case code
            case message
            case error
            case errorDescription = "error_description"
            case retryAfterSeconds
        }
    }
}
