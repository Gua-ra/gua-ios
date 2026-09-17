//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Combine
@testable import ElementX
import XCTest

/// GUA FORK: the identity-reset entry point into reauthentication.
///
/// It is the third of the three reauth screens and the least reachable by hand, so the properties
/// the other two are tested for are pinned here too: no code exists until the account's own number
/// is given, both calls carry that number under this operation's scope, and a refusal says only
/// that the number is not this account's.
@MainActor
class EncryptionResetPasswordScreenViewModelTests: XCTestCase {
    private var passwordPublisher: PassthroughSubject<String, Never>!
    private var identityService: EncryptionResetIdentityServiceStub!
    private var viewModel: EncryptionResetPasswordScreenViewModel!

    private var context: EncryptionResetPasswordScreenViewModelType.Context {
        viewModel.context
    }

    override func setUpWithError() throws {
        passwordPublisher = PassthroughSubject<String, Never>()
        identityService = EncryptionResetIdentityServiceStub()
        let clientProxy = ClientProxyMock(.init())
        clientProxy.accessToken = "access-token"
        viewModel = EncryptionResetPasswordScreenViewModel(passwordPublisher: passwordPublisher,
                                                           clientProxy: clientProxy,
                                                           identityServiceClient: identityService)
    }

    /// Identity-service never says which number an account is on, so the number is asked for and no
    /// code exists until it matches.
    func testNoCodeIsSentUntilTheAccountsNumberIsGiven() async {
        context.send(viewAction: .sendReauthCode)
        await Task.yield()

        XCTAssertTrue(identityService.startPhones.isEmpty)
        XCTAssertEqual(context.viewState.reauthPhase, .idle)
    }

    /// Both calls carry the number, because the server keeps nothing between them, and the token is
    /// minted for this operation alone: one scoped to a deactivation cannot pay for a reset. The
    /// credentials the reset runs on are then fetched with that same token.
    func testTheNumberTravelsWithBothReauthCallsUnderTheResetScope() async throws {
        context.phoneNumber = "+14155550143"

        let deferredSend = deferFulfillment(context.observe(\.viewState.reauthPhase)) { $0 == .awaitingCode }
        context.send(viewAction: .sendReauthCode)
        try await deferredSend.fulfill()

        context.otpCode = "123456"
        let deferredAction = deferFulfillment(viewModel.actionsPublisher) { $0 == .passwordEntered }
        context.send(viewAction: .verifyReauthCode)
        try await deferredAction.fulfill()

        XCTAssertEqual(identityService.startPhones, ["+14155550143"])
        XCTAssertEqual(identityService.verifyCalls.map(\.phone), ["+14155550143"])
        XCTAssertEqual(identityService.verifyCalls.map(\.operation), [.identityReset])
        XCTAssertEqual(identityService.resetTokens, ["reauth-token"])
    }

    /// This screen has no country picker, so a number without its country code would go out as
    /// typed. The server would read it against its own default region and refuse it with the same
    /// neutral sentence a stranger's number earns, having already spent one of the five attempts
    /// the account gets in an hour. It is refused here instead, where the reason can be named.
    func testANumberThatIsNotE164NeverCostsAnAttempt() async throws {
        context.phoneNumber = "4155550143"

        let refusal = L10n.screenPhoneLoginInvalidNumber
        let deferred = deferFulfillment(context.observe(\.viewState.reauthPhase)) { $0 == .error(refusal) }
        context.send(viewAction: .sendReauthCode)
        try await deferred.fulfill()

        XCTAssertTrue(identityService.startPhones.isEmpty)
    }

    /// The refusal says only that this is not the number on the account, in the user's language.
    func testAWrongNumberShowsTheNeutralRefusalAndNothingAboutOtherAccounts() async throws {
        identityService.startError = IdentityServiceError.reauthPhoneMismatch
        context.phoneNumber = "+14155550199"

        let refusal = L10n.screenAccountReauthPhoneMismatch
        let deferred = deferFulfillment(context.observe(\.viewState.reauthPhase)) { $0 == .error(refusal) }
        context.send(viewAction: .sendReauthCode)
        try await deferred.fulfill()

        XCTAssertTrue(identityService.verifyCalls.isEmpty, "A refused number never reaches the verify call")
    }
}

// MARK: - Stub

/// GUA FORK: identity-service as this screen sees it, which is the two reauth calls and the
/// credentials they authorize.
@MainActor
private final class EncryptionResetIdentityServiceStub: IdentityServiceClientProtocol {
    struct VerifyCall {
        let phone: String
        let operation: ReauthOperation
    }

    var startError: Error?
    private(set) var startPhones: [String] = []
    private(set) var verifyCalls: [VerifyCall] = []
    private(set) var resetTokens: [String] = []

    func startAccountReauth(accessToken: String, phone: String, language: String?) async throws {
        startPhones.append(phone)
        if let startError {
            throw startError
        }
    }

    func verifyAccountReauth(accessToken: String, phone: String, code: String, operation: ReauthOperation) async throws -> String {
        verifyCalls.append(VerifyCall(phone: phone, operation: operation))
        return "reauth-token"
    }

    func resetIdentityCredentials(accessToken: String, reauthToken: String) async throws -> IdentityResetCredentials {
        resetTokens.append(reauthToken)
        return IdentityResetCredentials(userId: "@someone:example.invalid", password: "ephemeral")
    }

    func lookupContacts(accessToken: String, phones: [String]) async throws -> [ContactMatch] {
        []
    }

    func deactivateAccount(accessToken: String, reauthToken: String, eraseData: Bool) async throws { }

    func securityStatus(accessToken: String) async throws -> AccountSecurityStatus {
        AccountSecurityStatus(hasPin: true,
                              passkeyRegistered: false,
                              preferredFactor: .pin,
                              phoneChangeStepUpFactors: [.pin],
                              pinStepUpHoldRemainingSeconds: 0)
    }

    func startPinChange(accessToken: String,
                        phone: String,
                        currentPin: String?,
                        passkeyStepUpID: String?,
                        passkeyAssertion: PasskeyAssertion?) async throws -> String {
        ""
    }

    func completePinChange(accessToken: String, challengeId: String, otpCode: String, newPin: String) async throws { }
    func cancelAccountRecovery(accessToken: String) async throws { }
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

    func startPinEnrollment(accessToken: String) async throws -> URL {
        URL(string: "https://example.invalid")!
    }
}
