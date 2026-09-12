//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

@testable import ElementX
import XCTest

/// GUA FORK: the change-phone flow against the real account contract.
///
/// These are mostly about orderings rather than about screens: which factor is offered, what is
/// sent before a step-up exists, and what happens to a refusal. Each one of them is a property that
/// was either broken or unexpressed before, so a regression in any of them is a security change
/// rather than a cosmetic one.
@MainActor
class ChangePhoneScreenViewModelTests: XCTestCase {
    private var identityService: ChangePhoneIdentityServiceStub!
    private var passkeyPresenter: PasskeyStepUpPresenterStub!
    private var viewModel: ChangePhoneScreenViewModel!

    private var context: ChangePhoneScreenViewModelType.Context {
        viewModel.context
    }

    private static let assertion = PasskeyAssertion(id: "credential-id",
                                                    response: .init(clientDataJSON: "client-data",
                                                                    authenticatorData: "authenticator-data",
                                                                    signature: "signature",
                                                                    userHandle: "user-handle"))

    private func makeViewModel(status: AccountSecurityStatus,
                               passkeyResult: Result<PasskeyAssertion, Error> = .success(ChangePhoneScreenViewModelTests.assertion),
                               presentsPasskeys: Bool = true) {
        identityService = ChangePhoneIdentityServiceStub(status: status)
        passkeyPresenter = PasskeyStepUpPresenterStub(result: passkeyResult)
        let clientProxy = ClientProxyMock(.init())
        clientProxy.accessToken = "access-token"
        viewModel = ChangePhoneScreenViewModel(clientProxy: clientProxy,
                                               identityServiceClient: identityService,
                                               userIndicatorController: UserIndicatorControllerMock(),
                                               passkeyStepUpPresenter: presentsPasskeys ? passkeyPresenter : nil)
    }

    private static func status(hasPin: Bool,
                               passkeyRegistered: Bool,
                               pinHold: Int? = 0,
                               acceptedFactors: [AuthFactor] = [.passkey, .pin]) -> AccountSecurityStatus {
        AccountSecurityStatus(hasPin: hasPin,
                              passkeyRegistered: passkeyRegistered,
                              preferredFactor: passkeyRegistered ? .passkey : (hasPin ? .pin : .phoneOTP),
                              phoneChangeStepUpFactors: acceptedFactors,
                              pinStepUpHoldRemainingSeconds: pinHold)
    }

    private func waitForPhase(_ phase: ChangePhoneScreenPhase) async throws {
        let deferred = deferFulfillment(context.observe(\.viewState.phase)) { $0 == phase }
        try await deferred.fulfill()
    }

    private func enterCode(_ code: String) {
        context.code = code
        context.send(viewAction: .codeChanged)
    }

    private func enterNewNumber() throws {
        try context.send(viewAction: .countrySelected(XCTUnwrap(Country.find(isoCode: "US"))))
        context.localPhoneNumber = "5551234567"
        context.send(viewAction: .phoneChanged)
        context.send(viewAction: .continueTapped)
    }

    /// Drives the flow as far as the new-number step, which is where the step-up begins.
    private func advanceToNewPhone() async throws {
        context.send(viewAction: .start)
        try await waitForPhase(.reauth)
        enterCode("123456")
        try await waitForPhase(.newPhone)
    }

    // MARK: - The gate, before anything is sent

    func testAccountWithNoFactorIsBlockedBeforeAnySMS() async throws {
        makeViewModel(status: Self.status(hasPin: false, passkeyRegistered: false))

        context.send(viewAction: .start)
        try await waitForPhase(.stepUpRequired)

        XCTAssertEqual(context.viewState.stepUpBlockReason, .noFactorRegistered)
        XCTAssertEqual(identityService.startReauthCallCount, 0, "No code may be sent to an account that cannot finish the flow")
    }

    func testPassKeyHolderWithNoPinIsNotToldToCreateOne() async throws {
        makeViewModel(status: Self.status(hasPin: false, passkeyRegistered: true))

        context.send(viewAction: .start)
        try await waitForPhase(.reauth)

        XCTAssertEqual(context.viewState.stepUpFactors, [.passkey])
    }

    func testPinOnlyAccountInsideTheHoldWaitsWithoutAnySMS() async throws {
        makeViewModel(status: Self.status(hasPin: true, passkeyRegistered: false, pinHold: 3600))

        context.send(viewAction: .start)
        try await waitForPhase(.cooldown)

        XCTAssertEqual(context.viewState.cooldownRemainingSeconds, 3600)
        XCTAssertEqual(identityService.startReauthCallCount, 0)
    }

    /// The hold the server reports is the PIN's. Holding a passkey holder to it would make them
    /// wait out a factor they are not going to spend.
    func testPasskeyHolderIsNotHeldByThePinHold() async throws {
        makeViewModel(status: Self.status(hasPin: true, passkeyRegistered: true, pinHold: 3600))

        context.send(viewAction: .start)
        try await waitForPhase(.reauth)
    }

    /// A deployment that does not report the hold must not be read as "no hold" nor as a block. The
    /// server still refuses mid-flow, and that refusal is handled.
    func testUnreportedHoldDoesNotBlockTheFlow() async throws {
        makeViewModel(status: Self.status(hasPin: true, passkeyRegistered: false, pinHold: nil))

        context.send(viewAction: .start)
        try await waitForPhase(.reauth)
    }

    // MARK: - Producing the step-up

    func testPasskeyAssertionSettlesTheStepUpAndThePinIsNeverAsked() async throws {
        makeViewModel(status: Self.status(hasPin: true, passkeyRegistered: true))
        try await advanceToNewPhone()

        try enterNewNumber()
        try await waitForPhase(.otp)

        XCTAssertEqual(passkeyPresenter.callCount, 1)
        let call = try XCTUnwrap(identityService.startPhoneChangeCalls.last)
        XCTAssertNil(call.pin, "A caller that proved a passkey must not also be asked for the PIN")
        XCTAssertEqual(call.passkeyStepUpID, identityService.stepUpOptions.stepUpID)
        XCTAssertEqual(call.passkeyAssertion, Self.assertion)
    }

    func testPasskeyThatCannotBeProducedFallsBackToThePin() async throws {
        makeViewModel(status: Self.status(hasPin: true, passkeyRegistered: true),
                      passkeyResult: .failure(PasskeyStepUpError.unavailable))
        try await advanceToNewPhone()

        try enterNewNumber()
        try await waitForPhase(.pin)

        XCTAssertTrue(identityService.startPhoneChangeCalls.isEmpty,
                      "Nothing may be sent to the new number before a step-up has been accepted")
        XCTAssertFalse(context.viewState.passkeyRefusedByServer,
                       "A ceremony that failed on the device says nothing about the credential")

        enterCode("654321")
        try await waitForPhase(.otp)

        let call = try XCTUnwrap(identityService.startPhoneChangeCalls.last)
        XCTAssertEqual(call.pin, "654321")
        XCTAssertNil(call.passkeyAssertion)
        XCTAssertNil(call.passkeyStepUpID, "A ceremony that never happened must not be referenced")
    }

    /// A device that cannot present a ceremony at all is the same case, and it is decided here
    /// rather than reported to the server.
    func testDeviceWithoutAPasskeyPresenterUsesThePin() async throws {
        makeViewModel(status: Self.status(hasPin: true, passkeyRegistered: true), presentsPasskeys: false)
        try await advanceToNewPhone()

        try enterNewNumber()
        try await waitForPhase(.pin)
    }

    func testPasskeyFailureWithNothingUnderneathBlocks() async throws {
        makeViewModel(status: Self.status(hasPin: false, passkeyRegistered: true),
                      passkeyResult: .failure(PasskeyStepUpError.unavailable))
        try await advanceToNewPhone()

        try enterNewNumber()
        try await waitForPhase(.stepUpRequired)

        XCTAssertEqual(context.viewState.stepUpBlockReason, .passkeyUnusableHere)
        XCTAssertTrue(identityService.startPhoneChangeCalls.isEmpty)
    }

    // MARK: - What the server answers

    func testStepUpRequiredIsAHardBlock() async throws {
        makeViewModel(status: Self.status(hasPin: true, passkeyRegistered: false))
        identityService.startPhoneChangeResult = .failure(IdentityServiceError.stepUpRequired)
        try await advanceToNewPhone()

        try enterNewNumber()
        try await waitForPhase(.pin)
        enterCode("654321")
        try await waitForPhase(.stepUpRequired)

        XCTAssertEqual(identityService.startPhoneChangeCalls.count, 1, "A hard block is not retried with a weaker proof")
        XCTAssertTrue(context.viewState.reauthToken.isEmpty, "The spent reauth token must not survive the refusal")
    }

    func testFreshFactorCooldownFromTheServerShowsTheWait() async throws {
        makeViewModel(status: Self.status(hasPin: true, passkeyRegistered: false))
        identityService.startPhoneChangeResult = .failure(IdentityServiceError.twoFactorCooldown(retryAfterSeconds: 7200))
        try await advanceToNewPhone()

        try enterNewNumber()
        try await waitForPhase(.pin)
        enterCode("654321")
        try await waitForPhase(.cooldown)

        XCTAssertEqual(context.viewState.cooldownRemainingSeconds, 7200)
        XCTAssertTrue(context.viewState.reauthToken.isEmpty)
    }

    func testPerAccountCooldownShowsTheWait() async throws {
        makeViewModel(status: Self.status(hasPin: true, passkeyRegistered: false))
        identityService.startPhoneChangeResult = .failure(IdentityServiceError.phoneChangeCooldown(retryAfterSeconds: 86400))
        try await advanceToNewPhone()

        try enterNewNumber()
        try await waitForPhase(.pin)
        enterCode("654321")
        try await waitForPhase(.cooldown)

        XCTAssertEqual(context.viewState.cooldownRemainingSeconds, 86400)
    }

    func testExpiredReauthTokenRestartsWhereItIsMinted() async throws {
        makeViewModel(status: Self.status(hasPin: true, passkeyRegistered: false))
        identityService.startPhoneChangeResult = .failure(IdentityServiceError.invalidReauthToken)
        try await advanceToNewPhone()

        try enterNewNumber()
        try await waitForPhase(.pin)
        enterCode("654321")
        try await waitForPhase(.reauth)

        XCTAssertEqual(identityService.startReauthCallCount, 2, "A fresh code is needed for a fresh token")
        XCTAssertTrue(context.viewState.reauthToken.isEmpty)
    }

    /// The product rule at its sharpest. A refusal that comes back from the SERVER is precisely the
    /// case the PIN fallback exists for: the credential is registered and the ceremony did run, so
    /// re-offering it would walk into the identical refusal and the PIN would never get its turn.
    /// The reauth token was spent by the refused attempt, so a fresh one has to be minted first.
    func testServerRefusedPasskeyLetsThePinFinishTheChange() async throws {
        makeViewModel(status: Self.status(hasPin: true, passkeyRegistered: true))
        identityService.startPhoneChangeResults = [.failure(IdentityServiceError.passkeyUserVerificationRequired)]
        try await advanceToNewPhone()

        try enterNewNumber()
        try await waitForPhase(.reauth)

        XCTAssertEqual(passkeyPresenter.callCount, 1)
        XCTAssertTrue(context.viewState.reauthToken.isEmpty, "The refused attempt spent the token")
        XCTAssertEqual(identityService.startReauthCallCount, 2, "A spent token has to be re-minted before the PIN can be tried")

        enterCode("123456")
        try await waitForPhase(.newPhone)
        try enterNewNumber()
        try await waitForPhase(.pin)

        XCTAssertEqual(passkeyPresenter.callCount, 1, "The refused ceremony must not be run into the same refusal again")

        enterCode("654321")
        try await waitForPhase(.otp)

        XCTAssertEqual(identityService.startPhoneChangeCalls.count, 2)
        let call = try XCTUnwrap(identityService.startPhoneChangeCalls.last)
        XCTAssertEqual(call.pin, "654321", "The PIN is the fallback, so it has to be able to settle the change")
        XCTAssertNil(call.passkeyAssertion)
        XCTAssertNil(call.passkeyStepUpID)
    }

    /// The server spends the reauth token before it checks the PIN, so one wrong digit costs the
    /// whole reauth leg. The flow has to say that and mint a new token, rather than returning to a
    /// PIN field that can only fail again and then blaming an expiry that never happened.
    func testWrongPinRestartsAtReauthAndReportsTheRealReason() async throws {
        makeViewModel(status: Self.status(hasPin: true, passkeyRegistered: false))
        identityService.startPhoneChangeResults = [.failure(IdentityServiceError.invalidPin)]
        try await advanceToNewPhone()

        try enterNewNumber()
        try await waitForPhase(.pin)
        enterCode("111111")
        try await waitForPhase(.reauth)

        XCTAssertTrue(context.viewState.reauthToken.isEmpty)
        XCTAssertEqual(identityService.startReauthCallCount, 2)
        XCTAssertEqual(context.viewState.errorMessage, L10n.screenChangePhonePinIncorrect)

        enterCode("123456")
        try await waitForPhase(.newPhone)
        try enterNewNumber()
        try await waitForPhase(.pin)
        enterCode("654321")
        try await waitForPhase(.otp)

        XCTAssertEqual(identityService.startPhoneChangeCalls.map(\.pin), ["111111", "654321"])
    }

    /// No exit from `/start` may keep the token, including the ones that simply give up: the server
    /// spends it on entry, so anything that carried it forward would report a stale token instead of
    /// the reason the attempt actually failed.
    func testAnAbandonedAttemptDoesNotKeepTheSpentToken() async throws {
        makeViewModel(status: Self.status(hasPin: true, passkeyRegistered: false))
        identityService.startPhoneChangeResults = [.failure(IdentityServiceError.rateLimited)]
        try await advanceToNewPhone()

        try enterNewNumber()
        try await waitForPhase(.pin)
        enterCode("654321")
        try await waitForPhase(.intro)

        XCTAssertTrue(context.viewState.reauthToken.isEmpty)
        XCTAssertEqual(identityService.startReauthCallCount, 1, "Giving up must not spend another code on the user's behalf")
    }

    func testCompletingTheChangeRedeemsTheChallengeFromStart() async throws {
        makeViewModel(status: Self.status(hasPin: true, passkeyRegistered: true))
        try await advanceToNewPhone()

        try enterNewNumber()
        try await waitForPhase(.otp)
        enterCode("112233")
        try await waitForPhase(.done)

        XCTAssertEqual(identityService.completeCalls.map(\.challengeId), ["challenge-id"])
        XCTAssertEqual(identityService.completeCalls.map(\.code), ["112233"])
    }
}

// MARK: - Stubs

@MainActor
private final class PasskeyStepUpPresenterStub: PasskeyStepUpPresenting {
    private let result: Result<PasskeyAssertion, Error>
    private(set) var callCount = 0

    init(result: Result<PasskeyAssertion, Error>) {
        self.result = result
    }

    func assertion(for options: PasskeyStepUpOptions) async throws -> PasskeyAssertion {
        callCount += 1
        return try result.get()
    }
}

@MainActor
private final class ChangePhoneIdentityServiceStub: IdentityServiceClientProtocol {
    struct StartPhoneChangeCall {
        let pin: String?
        let passkeyStepUpID: String?
        let passkeyAssertion: PasskeyAssertion?
    }

    struct CompleteCall {
        let challengeId: String
        let code: String
    }

    var status: AccountSecurityStatus
    var stepUpOptions = PasskeyStepUpOptions(stepUpID: "step-up-id",
                                             relyingPartyID: "example.invalid",
                                             challenge: Data([1, 2, 3]),
                                             allowedCredentialIDs: [Data([4, 5, 6])])
    var startPhoneChangeResult: Result<PhoneChangeChallenge, Error> = .success(PhoneChangeChallenge(challengeID: "challenge-id",
                                                                                                    otpExpiresInSeconds: 300))
    /// Answers for successive calls, oldest first, for the flows where the server refuses once and
    /// then accepts. Once it runs dry `startPhoneChangeResult` answers everything, so the
    /// single-answer tests below read exactly as they did.
    var startPhoneChangeResults: [Result<PhoneChangeChallenge, Error>] = []
    private(set) var startReauthCallCount = 0
    private(set) var startPhoneChangeCalls: [StartPhoneChangeCall] = []
    private(set) var completeCalls: [CompleteCall] = []

    init(status: AccountSecurityStatus) {
        self.status = status
    }

    func securityStatus(accessToken: String) async throws -> AccountSecurityStatus {
        status
    }

    func startAccountReauth(accessToken: String, language: String?) async throws {
        startReauthCallCount += 1
    }

    func verifyAccountReauth(accessToken: String, code: String, operation: ReauthOperation) async throws -> String {
        XCTAssertEqual(operation, .phoneChange, "A phone change must not spend a token scoped to another operation")
        return "reauth-token"
    }

    func startPasskeyStepUp(accessToken: String) async throws -> PasskeyStepUpOptions {
        stepUpOptions
    }

    func startPhoneChange(accessToken: String,
                          reauthToken: String,
                          newPhone: String,
                          pin: String?,
                          passkeyStepUpID: String?,
                          passkeyAssertion: PasskeyAssertion?,
                          language: String?) async throws -> PhoneChangeChallenge {
        startPhoneChangeCalls.append(StartPhoneChangeCall(pin: pin,
                                                          passkeyStepUpID: passkeyStepUpID,
                                                          passkeyAssertion: passkeyAssertion))
        let result = startPhoneChangeResults.isEmpty ? startPhoneChangeResult : startPhoneChangeResults.removeFirst()
        return try result.get()
    }

    func completePhoneChange(accessToken: String, challengeId: String, code: String) async throws {
        completeCalls.append(CompleteCall(challengeId: challengeId, code: code))
    }

    func lookupContacts(accessToken: String, phones: [String]) async throws -> [ContactMatch] {
        []
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
    func startPasskeyEnrollment(accessToken: String) async throws -> URL {
        URL(string: "https://example.invalid")!
    }
}
