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
    /// 403 `step_up_required`: the account holds neither a PIN nor a passkey, and the operation
    /// demands one of them. A hard block, not a prompt to retry: the operation is over until the
    /// user sets up a factor, and there is no reauth-token-only path behind it.
    case stepUpRequired
    /// The passkey step-up ceremony cannot be started for this account on this deployment: passkeys
    /// are off here, or the account has no registered credential to assert. Never a reason to give
    /// up, only a reason to offer the next factor down.
    case passkeyStepUpUnavailable
    /// 403 `passkey_user_verification_required`: the assertion proved possession of the device but
    /// not the human, which is the whole of what separates a step-up from a sign-in.
    case passkeyUserVerificationRequired
    /// Change-phone is temporarily blocked because the factor being spent was registered too
    /// recently (the fresh-2FA hold, which covers a new PIN and a new passkey alike).
    case twoFactorCooldown(retryAfterSeconds: Int?)
    /// 425 `phone_change_cooldown`: the minimum gap between two successful phone changes. A
    /// different refusal from the fresh-2FA hold above, and waiting out one does not clear the other.
    case phoneChangeCooldown(retryAfterSeconds: Int?)
    case invalidReauthToken
    case phoneAlreadyLinked
    /// 403 `reauth_phone_mismatch`: the number typed at a reauthentication step is not the one on
    /// the signed-in account. The server answers the same way whether the number is unknown or
    /// belongs to somebody else, and it says so in one fixed English sentence. The wording shown is
    /// this fork's own translated constant, which is a single string for every reason the number is
    /// wrong, so the neutrality holds in each language rather than only in the server's.
    case reauthPhoneMismatch
    /// 400 `invalid_phone_number`: the normalizer could not read the number at all. It says nothing
    /// about which account the number belongs to, and it must not be shown as though it did.
    case invalidPhoneNumber
    /// 409 `pin_already_set`: the account gained a PIN since this screen read its factor report, so
    /// there is nothing to enroll.
    case pinAlreadySet
    /// 409 `passkey_already_registered`: the same thing for a passkey. Kept apart from the PIN so
    /// the sentence can name the factor the account turns out to hold.
    case passkeyAlreadyRegistered
    /// 409 `step_up_unavailable`: the account can only prove itself with a passkey and this
    /// deployment has passkeys turned off, so there is no proof it can produce and no factor it can
    /// add here. The only way back into the account is the delayed recovery, which is why this is
    /// the one enrollment refusal whose copy sends the reader somewhere else entirely.
    case stepUpUnavailable
    /// 400 `invalid_redirect_uri`: the deployment does not permit the redirect this build asked the
    /// enrollment sheet to return to. It is a deployment's allowlist talking to a build, not
    /// anything the reader did or can fix, which is why the client answers it by asking again
    /// without a redirect rather than by showing it. A reader only ever sees this if that second
    /// attempt fails too, and then there is nothing truer to say than that something went wrong.
    case invalidRedirectURI
    /// `POST /account/genesis` answered 503: this deployment does not do account genesis. Callers treat
    /// it as "not supported here" and carry on with the existing signup, never as a failure.
    case genesisUnavailable
    /// `POST /account/genesis` answered 403: the deployment declines to issue under the recovery
    /// framework this client commits to, which ADM-008 decision 4 gates on ADM-002. Like 503 it means
    /// no handle exists to present, so callers take the no-handle bootstrap branch decision 6 calls
    /// not a failure rather than blocking the signup.
    case genesisIssuanceNotPermitted
    /// Anything `/account/authority/**` refused (ADM-009). One case with a typed refusal rather than
    /// twenty, because these are read by one feature that ships disabled, and a caller that does not
    /// know the chain has no branch to write against them.
    case authority(AuthorityRefusal)
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
        case let .authority(refusal): refusal.message
        case let .server(status, message): message ?? "Server error (\(status))."
        case let .transport(error): error.localizedDescription
        case let .decoding(error): "Could not parse the server response: \(error.localizedDescription)"
        }
    }

    /// Coarse, human-friendly rendering of a remaining-duration in seconds, e.g. "7 days",
    /// "3 hours", "5 minutes". Rounds up so we never under-promise availability.
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

/// GUA FORK: why an authority transition was refused, by the stable code identity-service returns.
///
/// The codes are the server's, so a refusal can be read against ADM-009 rather than against a status
/// line: 403 carries the hold, the artifact and the native-session rule, and 409 carries three different
/// conflicts. A code this build has not heard of stays ``unrecognised`` rather than being rounded to the
/// nearest one it knows.
enum AuthorityRefusal: Equatable {
    /// `identity.authority.enabled` is false here, or this deployment predates the endpoints. Per the
    /// wire contract this is "this build does not have the feature", never an error worth showing.
    case disabled
    /// No accepted factor was produced. A passkey or the PIN, and never a code sent to the number.
    case stepUpRequired
    /// The factor presented, or the account's last completed recovery, is inside the fresh-factor hold.
    case tooRecent(retryAfterSeconds: Int?)
    /// A session that is not the native app. The browser holds no authority, ever.
    case nativeSessionRequired
    case artifactUnconfirmed
    /// Adoption is off on this deployment: ADM-009 gate 3 keeps production adoption refused.
    case adoptionNotPermitted
    /// The challenge was spent, expired, or belongs to another session.
    case challengeInvalid
    /// The record's type is not permitted at that position or on that class of account.
    case positionRefused
    case pendingConflict
    /// The head moved: another device landed a record first. Re-read and decide again.
    case headConflict
    /// The account holds no chain row at all.
    case noAccount
    /// The doubling backoff of ADM-002 D2, or the one-window cooldown.
    case backoff(retryAfterSeconds: Int?)
    /// Refusals the surfaces in this build cannot reach, kept so the mapping is complete rather than
    /// silently landing on a generic error: this device may not sign, it is quarantined, the revocation
    /// would leave no device, or the opposition needs a device signature this app cannot make.
    case signerRefused
    case deviceQuarantined
    case lastDevice
    case oppositionDeviceRequired
    case approvalInvalid
    case approvalLimit
    /// The record was refused by the decoder, naming the rule. A client bug, not a user's problem.
    case invalidRecord(rule: String?)
    case unrecognised(code: String)

    init?(code: String?, retryAfterSeconds: Int?) {
        switch code {
        case "authority_disabled": self = .disabled
        case "authority_step_up_required": self = .stepUpRequired
        case "authority_factor_too_fresh", "authority_recovery_too_recent":
            self = .tooRecent(retryAfterSeconds: retryAfterSeconds)
        case "authority_native_session_required": self = .nativeSessionRequired
        case "authority_artifact_unconfirmed": self = .artifactUnconfirmed
        case "authority_adoption_not_permitted": self = .adoptionNotPermitted
        case "authority_challenge_invalid": self = .challengeInvalid
        case "authority_position_refused": self = .positionRefused
        case "authority_pending_conflict": self = .pendingConflict
        case "authority_head_conflict", "authority_account_mismatch": self = .headConflict
        case "authority_no_account": self = .noAccount
        case "authority_backoff", "authority_cooldown": self = .backoff(retryAfterSeconds: retryAfterSeconds)
        case "authority_signer_refused": self = .signerRefused
        case "authority_device_quarantined": self = .deviceQuarantined
        case "authority_last_device": self = .lastDevice
        case "authority_opposition_device_required", "authority_opposition_refused":
            self = .oppositionDeviceRequired
        case "authority_approval_invalid": self = .approvalInvalid
        case "authority_approval_limit": self = .approvalLimit
        case "invalid_authority_record": self = .invalidRecord(rule: nil)
        case let code? where code.hasPrefix("authority_"): self = .unrecognised(code: code)
        default: return nil
        }
    }

    /// Whether this refusal means the feature is not here, rather than that something went wrong.
    var isFeatureAbsent: Bool {
        self == .disabled
    }

    /// The sentence to show. Every refusal a shipped surface can reach has its own; the rest land on the
    /// generic one, because inventing copy for a state no screen can produce would be a claim that the
    /// state was handled.
    var message: String {
        switch self {
        case .disabled, .nativeSessionRequired, .artifactUnconfirmed, .signerRefused, .deviceQuarantined,
             .lastDevice, .oppositionDeviceRequired, .invalidRecord, .unrecognised:
            L10n.errorUnknown
        case .stepUpRequired:
            L10n.screenAccountAuthorityErrorStepUp
        case let .tooRecent(retry):
            if let retry, retry > 0 {
                L10n.screenAccountAuthorityErrorTooRecentIn(IdentityServiceError.humanReadableDuration(seconds: retry))
            } else {
                L10n.screenAccountAuthorityErrorTooRecent
            }
        case .adoptionNotPermitted:
            L10n.screenAccountAuthorityErrorNotPermitted
        case .challengeInvalid:
            L10n.screenAccountAuthorityErrorExpired
        case .positionRefused:
            L10n.screenAccountAuthorityErrorPosition
        case .pendingConflict:
            L10n.screenAccountAuthorityErrorPending
        case .headConflict:
            L10n.screenAccountAuthorityErrorConflict
        case .noAccount:
            L10n.screenAccountAuthorityErrorNoAccount
        case let .backoff(retry):
            if let retry, retry > 0 {
                L10n.screenAccountAuthorityErrorTooRecentIn(IdentityServiceError.humanReadableDuration(seconds: retry))
            } else {
                L10n.screenAccountAuthorityErrorTooRecent
            }
        case .approvalInvalid:
            L10n.screenAuthorityApprovalRefused
        case .approvalLimit:
            L10n.screenAuthorityApprovalMultiple
        }
    }
}

/// GUA FORK: what `POST /account/genesis` returns (ADM-008 decision 6). The handle is single-use and
/// expires with `expiresAt`; the server stores only its hash.
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
    /// Sends the reauth OTP, but only once `phone` turns out to be the number on the caller's own
    /// account. The server digests what is submitted and compares it with that account's directory
    /// binding, so the number is a proof rather than a routing hint: nothing is stored, and a
    /// number that is not this account's is refused identically whoever it belongs to.
    func startAccountReauth(accessToken: String, phone: String, language: String?) async throws
    /// Exchanges the reauth OTP for a single-use token scoped to `operation`. The number is
    /// submitted again because nothing was kept between the two calls, and the scope is not
    /// cosmetic: the server refuses a token presented for any other operation, so every caller
    /// names the one it is about to perform.
    func verifyAccountReauth(accessToken: String, phone: String, code: String, operation: ReauthOperation) async throws -> String
    func deactivateAccount(accessToken: String, reauthToken: String, eraseData: Bool) async throws
    func resetIdentityCredentials(accessToken: String, reauthToken: String) async throws -> IdentityResetCredentials
    /// GUA FORK: two-step verification. `GET /security/pin/status` reports the whole factor
    /// inventory, not just the PIN, and it is the signal every "which factor does this account
    /// need" decision reads.
    func securityStatus(accessToken: String) async throws -> AccountSecurityStatus
    /// Starts a PIN change and texts a code to `phone`. Authorized by a step-up passkey assertion when
    /// `passkeyStepUpID` and `passkeyAssertion` are supplied, in which case `currentPin` is not consulted,
    /// otherwise by `currentPin`.
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
    // GUA FORK: change phone number. Reauth by OTP to the CURRENT number first
    // (`/account/reauth/start` + `/account/reauth/verify` scoped to PHONE_CHANGE), then
    // `/account/phone/change/start`, which spends that token together with a step-up factor and
    // only then texts the NEW number, and finally `/account/phone/change/complete` with the code
    // that arrived there.
    func startPasskeyStepUp(accessToken: String) async throws -> PasskeyStepUpOptions
    func startPhoneChange(accessToken: String,
                          reauthToken: String,
                          newPhone: String,
                          pin: String?,
                          passkeyStepUpID: String?,
                          passkeyAssertion: PasskeyAssertion?,
                          language: String?) async throws -> PhoneChangeChallenge
    func completePhoneChange(accessToken: String, challengeId: String, code: String) async throws
    /// Begins passkey enrollment and returns the IdP-hosted URL to load in an
    /// authenticated web session. The flow finishes when that page redirects to
    /// the app's OIDC redirect URL.
    ///
    /// `redirectURI` is this build's own redirect, which is how the sheet finds its way back to the
    /// variant it was opened from: the QA and debug builds answer to different schemes from the
    /// release build, and a deployment that only knows one of them would otherwise return every
    /// enrollment to the release app. It is a request, not a decision: the server keeps the
    /// allowlist and the client falls back to the deployment's own default when it refuses.
    func startPasskeyEnrollment(accessToken: String, redirectURI: String?) async throws -> URL
    /// Begins PIN enrollment the same way, and for the same reason: a bearer session on its own
    /// must not add a durable factor, so the first PIN is set inside a web session that confirms
    /// the account first (a passkey, an existing PIN, or the account's own number and a code sent
    /// to it). Changing a PIN that already exists is a different flow and stays native.
    func startPinEnrollment(accessToken: String, redirectURI: String?) async throws -> URL
}

/// GUA FORK: the slice of identity-service that account genesis needs, kept separate from
/// `IdentityServiceClientProtocol` because this one call is unauthenticated and runs before any session
/// exists. Mirrors how `FederationRosterFetching` narrows the resolver.
protocol AccountGenesisRegistering: Sendable {
    /// Registers an on-device `AccountGenesis` and returns its accountId with a single-use attach
    /// handle. Self-authenticating: the body carries a possession proof under the key committed inside
    /// the genesis itself, which is what lets it run with no session to authenticate against.
    ///
    /// Both arguments are base64url without padding. Throws ``IdentityServiceError/genesisUnavailable``
    /// on 503 and ``IdentityServiceError/genesisIssuanceNotPermitted`` on 403. Both mean the deployment
    /// issues no handle, rather than that anything went wrong.
    func registerAccountGenesis(genesis: String, proof: String) async throws -> AccountGenesisRegistrationResponse
}

/// Ephemeral credentials minted by the identity-service for the Matrix
/// `m.login.password` UIA stage during `client.resetIdentity()`.
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

final class IdentityServiceClient: IdentityServiceClientProtocol, AccountGenesisRegistering, AccountAuthorityRequesting {
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

    /// Convenience initializer using the active `GuaDeployment`'s identity-service URL.
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
            // A field the deployment did not send stays absent here rather than becoming a value.
            // The hold used to default to 0, which reads as "no hold" and made the pre-check inert
            // against every server that had not started emitting it; `nil` says "not reported" and
            // lets the caller keep the server's own mid-flow refusal as the thing that decides.
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

    /// Mints a user-verifying passkey ceremony pinned to the authenticated caller
    /// (`POST /security/passkey/stepup/options`), whose assertion settles the phone-change step-up
    /// on its own.
    ///
    /// A deployment with passkeys off answers 404 and an account with no registered credential
    /// answers 409; both surface as ``IdentityServiceError/passkeyStepUpUnavailable`` so the caller
    /// offers the next factor down instead of treating it as a failure.
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
        // Every byte field on the wire is base64url. A ceremony this client cannot assemble
        // verbatim is not one to improvise: there is no rp id to fall back on that would not be a
        // guess, so it becomes "unavailable" and the caller asks for the PIN.
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
    /// token together with the step-up factor, and only then texts the NEW number, returning the
    /// challenge to redeem. The ordering is the server's and matters: no SMS reaches the new number
    /// until a step-up has actually been accepted.
    ///
    /// Exactly one step-up is offered per call: the assertion when the device produced one,
    /// otherwise the PIN. There is no field for saying which factor the device could not use, and
    /// none is invented here.
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

    /// Both enrollments answer the same way: a one-time URL on the sign-in origin, opened in an
    /// authenticated web view, which is where the account is confirmed before anything is stored.
    ///
    /// The named redirect is asked for once and never insisted on. A deployment that has not
    /// allowlisted this build's scheme, or a server too old to know the field, refuses with
    /// `invalid_redirect_uri`; the same call then goes out with nothing named, which is what every
    /// build did before this. The enrollment still runs, and the sheet returns to the deployment's
    /// configured app instead of this one, which is a worse ending than the right scheme and a far
    /// better one than a QA build that cannot enroll a factor at all.
    private func startFactorEnrollment(path: String, accessToken: String, redirectURI: String?) async throws -> URL {
        do {
            return try await requestEnrollmentURL(path: path, accessToken: accessToken, redirectURI: redirectURI)
        } catch IdentityServiceError.invalidRedirectURI where redirectURI != nil {
            // Never logged in full: the value is this build's own scheme, and the refusal is about
            // the deployment's allowlist rather than about anything in it.
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
        // 503 and 403 are the deployment saying no handle exists to present: genesis is off here, or
        // it declines to issue under this recovery framework. Neither is a failure. Everything else
        // that is not a 201 is, and the caller must not quietly create an account without one.
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

    // MARK: - Account authority

    func authorityChallenge(accessToken: String,
                            purpose: AuthorityPurpose,
                            stepUp: AuthorityStepUp) async throws -> AuthorityChallenge {
        struct Body: Encodable {
            let purpose: String
            let passkeyStepUpId: String?
            let passkeyCredential: PasskeyAssertion?
            let pin: String?
        }
        struct Response: Decodable {
            let challenge: String
            let expiresInSeconds: Int
        }
        // Exactly one step-up per call. There is no field for "the factor this device could not use",
        // and none is invented: that claim costs an attacker nothing and could only ever be a request
        // for the weaker factor.
        let body = switch stepUp {
        case let .passkey(stepUpID, assertion):
            Body(purpose: purpose.rawValue, passkeyStepUpId: stepUpID, passkeyCredential: assertion, pin: nil)
        case let .pin(pin):
            Body(purpose: purpose.rawValue, passkeyStepUpId: nil, passkeyCredential: nil, pin: pin)
        }
        let (data, _) = try await sendAuthenticated(path: "/account/authority/challenge",
                                                    accessToken: accessToken,
                                                    body: body,
                                                    language: nil,
                                                    expectsBody: true)
        do {
            let response = try decoder.decode(Response.self, from: data)
            return AuthorityChallenge(challenge: response.challenge,
                                      expiresAt: Date().addingTimeInterval(TimeInterval(max(0, response.expiresInSeconds))))
        } catch {
            throw IdentityServiceError.decoding(error)
        }
    }

    func submitAuthorityAdoption(accessToken: String,
                                 record: String,
                                 signature: String,
                                 challenge: String,
                                 recoveryArtifactConfirmed: Bool) async throws -> AuthoritySubmission {
        struct Body: Encodable {
            let record: String
            let signature: String
            /// The challenge travels back with the record. The server stores only its SHA-256, so it
            /// cannot rebuild the preimage without it, and holding the value would mean a database dump
            /// handed an attacker something signable.
            let challenge: String
            let recoveryArtifactConfirmed: Bool
        }
        return try await submitAuthorityRecord(path: "/account/authority/adopt",
                                               accessToken: accessToken,
                                               body: Body(record: record,
                                                          signature: signature,
                                                          challenge: challenge,
                                                          recoveryArtifactConfirmed: recoveryArtifactConfirmed))
    }

    func submitAuthorityDeviceGrant(accessToken: String,
                                    record: String,
                                    signature: String,
                                    challenge: String) async throws -> AuthoritySubmission {
        struct Body: Encodable {
            let record: String
            let signature: String
            let challenge: String
        }
        return try await submitAuthorityRecord(path: "/account/authority/device/grant",
                                               accessToken: accessToken,
                                               body: Body(record: record, signature: signature, challenge: challenge))
    }

    func authorityState(accessToken: String) async throws -> AuthorityChainState {
        struct Response: Decodable {
            let accountId: String
            let accountClass: String
            let state: String
            let headSeq: Int64
            let headHash: String
            let devices: [Device]
            let pending: Pending?

            struct Device: Decodable {
                let deviceKey: String
                let label: String?
                let state: String
                let quarantineUntilEpochSeconds: Int64?
                let grantedSeq: Int64
            }

            struct Pending: Decodable {
                let type: String
                let seq: Int64
                let effectiveAtEpochSeconds: Int64
                let recordHash: String
            }
        }
        let data = try await getAuthenticated(path: "/account/authority", accessToken: accessToken)
        let response: Response
        do {
            response = try decoder.decode(Response.self, from: data)
        } catch {
            throw IdentityServiceError.decoding(error)
        }
        // The id is parsed rather than carried as a string: the client signs over its 34 raw bytes, so an
        // id it cannot re-derive canonically is one it must not sign anything under.
        guard let accountID = try? AccountID.parse(response.accountId) else {
            throw IdentityServiceError.decoding(AccountGenesisError.badAccountID)
        }
        return AuthorityChainState(accountID: accountID,
                                   accountClass: AuthorityAccountClass(wireValue: response.accountClass),
                                   state: AuthorityChainStateName(wireValue: response.state),
                                   headSeq: response.headSeq,
                                   headHash: response.headHash,
                                   devices: response.devices.map { device in
                                       AuthorityDeviceSummary(deviceKey: device.deviceKey,
                                                              label: device.label ?? "",
                                                              state: AuthorityDeviceState(wireValue: device.state),
                                                              quarantineUntil: device.quarantineUntilEpochSeconds.map {
                                                                  Date(timeIntervalSince1970: TimeInterval($0))
                                                              },
                                                              grantedSeq: device.grantedSeq)
                                   },
                                   pending: response.pending.map { pending in
                                       AuthorityPendingTransition(type: pending.type,
                                                                  seq: pending.seq,
                                                                  effectiveAt: Date(timeIntervalSince1970: TimeInterval(pending.effectiveAtEpochSeconds)),
                                                                  recordHash: pending.recordHash)
                                   })
    }

    func liveAuthorityApprovals(accessToken: String) async throws -> [AuthorityApproval] {
        struct Response: Decodable {
            let approvalId: String
            let code: String
            let action: String?
            let actionDigest: String
            let challenge: String
            let expiresAtEpochSeconds: Int64
        }
        let data = try await getAuthenticated(path: "/account/authority/approval", accessToken: accessToken)
        do {
            return try decoder.decode([Response].self, from: data).map { approval in
                AuthorityApproval(approvalID: approval.approvalId,
                                  code: approval.code,
                                  action: approval.action?.isEmpty == true ? nil : approval.action,
                                  actionDigest: approval.actionDigest,
                                  challenge: approval.challenge,
                                  expiresAt: Date(timeIntervalSince1970: TimeInterval(approval.expiresAtEpochSeconds)))
            }
        } catch {
            throw IdentityServiceError.decoding(error)
        }
    }

    func signAuthorityApproval(accessToken: String, approvalID: String, signature: String) async throws {
        struct Body: Encodable { let signature: String }
        // The id is percent-encoded rather than interpolated: it is base64url, so it never needs it
        // today, but a path built by concatenation is one malformed value away from addressing something
        // else on this service.
        let escaped = approvalID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        guard !escaped.isEmpty else { throw IdentityServiceError.invalidURL }
        try await sendAuthenticated(path: "/account/authority/approval/\(escaped)/sign",
                                    accessToken: accessToken,
                                    body: Body(signature: signature),
                                    language: nil,
                                    expectsBody: false)
    }

    /// What every record submission answers with. Declared beside the method rather than inside it,
    /// because a generic function cannot nest a type.
    private struct AuthoritySubmissionResponse: Decodable {
        let seq: Int64
        let state: String
        let effectiveAtEpochSeconds: Int64
        let recordHash: String
    }

    /// The four record submissions answer the same way, so they share one path through the client.
    private func submitAuthorityRecord(path: String,
                                       accessToken: String,
                                       body: some Encodable) async throws -> AuthoritySubmission {
        let (data, _) = try await sendAuthenticated(path: path,
                                                    accessToken: accessToken,
                                                    body: body,
                                                    language: nil,
                                                    expectsBody: true)
        do {
            let response = try decoder.decode(AuthoritySubmissionResponse.self, from: data)
            return AuthoritySubmission(seq: response.seq,
                                       isPending: response.state == "PENDING",
                                       effectiveAt: Date(timeIntervalSince1970: TimeInterval(response.effectiveAtEpochSeconds)),
                                       recordHash: response.recordHash)
        } catch {
            throw IdentityServiceError.decoding(error)
        }
    }

    /// An authenticated GET. The two authority reads are the only GETs with a typed body in this client,
    /// and they go through here rather than each assembling a request of its own.
    private func getAuthenticated(path: String, accessToken: String) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else {
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
            throw Self.mappedError(status: httpResponse.statusCode,
                                   body: try? decoder.decode(ErrorBody.self, from: data),
                                   retryAfterHeader: httpResponse.value(forHTTPHeaderField: "Retry-After"),
                                   path: path)
        }
        return data
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

    /// Turns a refusal into the typed error the screens branch on.
    ///
    /// The mapping is by error code rather than by status, because the code is what the server
    /// promises and a status is shared by refusals that mean different things: 403 carries both the
    /// hard block and a passkey that did not verify its user, and 425 carries two cooldowns that do
    /// not substitute for one another. An unrecognized code stays a plain server error rather than
    /// being rounded to the nearest known one.
    private static func mappedError(status: Int, body: ErrorBody?, retryAfterHeader: String?, path: String) -> IdentityServiceError {
        let retry = body?.retryAfterSeconds ?? retryAfterHeader.flatMap(Int.init)
        if let mapped = authorityError(code: body?.code, status: status, path: path, retryAfterSeconds: retry)
            ?? passkeyError(code: body?.code, status: status, path: path)
            ?? waitError(code: body?.code, retryAfterSeconds: retry)
            ?? credentialError(code: body?.code) {
            return mapped
        }
        if status == 429 {
            return .rateLimited
        }
        return .server(status: status, message: body?.message ?? body?.errorDescription ?? body?.error)
    }

    /// Everything `/account/authority/**` refuses, mapped by the server's own code.
    ///
    /// The path check is what keeps this from claiming refusals that are not the chain's: only an
    /// authority endpoint can answer with an authority code, and only there does a bare 503 or 404 mean
    /// the feature is absent rather than that the service is in trouble. A deployment that predates the
    /// endpoints answers 404, and the wire contract reads both as "this build does not have the feature".
    private static func authorityError(code: String?, status: Int, path: String, retryAfterSeconds: Int?) -> IdentityServiceError? {
        guard path.hasPrefix("/account/authority") else { return nil }
        if let refusal = AuthorityRefusal(code: code, retryAfterSeconds: retryAfterSeconds) {
            return .authority(refusal)
        }
        return status == 503 || status == 404 ? .authority(.disabled) : nil
    }

    /// Everything that means "the passkey path is not available to this caller right now". All of
    /// it falls back to the next factor rather than ending the operation, which is why a refused
    /// assertion and an account with no credential land in the same place.
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

    /// The refusals that expire on their own. They are kept apart because waiting out one of them
    /// does nothing for the others.
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
    ///
    /// The mismatch drops the server's message. That message is one fixed English sentence, so
    /// carrying it through would show English to everybody; the local string says exactly the same
    /// thing and is, like the server's, a single constant for every reason the number is wrong.
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
