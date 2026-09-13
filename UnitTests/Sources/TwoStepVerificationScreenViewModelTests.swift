//
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import XCTest

@MainActor
class TwoStepVerificationScreenViewModelTests: XCTestCase {
    var viewModel: TwoStepVerificationScreenViewModel!

    var context: TwoStepVerificationScreenViewModelType.Context {
        viewModel.context
    }

    private var identityService: TwoStepVerificationIdentityServiceStub!

    override func setUpWithError() throws {
        makeViewModel(status: Self.status(hasPin: true, passkeyRegistered: false))
        // Put the screen into the phone-entry phase so phoneChanged actions are meaningful.
        context.send(viewAction: .startChange)
    }

    private var passkeyPresenter: TwoStepPasskeyPresenterStub!

    private static let assertion = PasskeyAssertion(id: "credential-id",
                                                    response: .init(clientDataJSON: "client-data",
                                                                    authenticatorData: "authenticator-data",
                                                                    signature: "signature",
                                                                    userHandle: "user-handle"))

    private func makeViewModel(status: AccountSecurityStatus?,
                               passkeyResult: Result<PasskeyAssertion, Error> = .success(TwoStepVerificationScreenViewModelTests.assertion),
                               presentsPasskeys: Bool = true) {
        identityService = TwoStepVerificationIdentityServiceStub(status: status)
        passkeyPresenter = TwoStepPasskeyPresenterStub(result: passkeyResult)
        let clientProxy = ClientProxyMock(.init())
        clientProxy.accessToken = "access-token"
        viewModel = TwoStepVerificationScreenViewModel(clientProxy: clientProxy,
                                                       identityServiceClient: identityService,
                                                       userIndicatorController: UserIndicatorControllerMock(),
                                                       passkeyStepUpPresenter: presentsPasskeys ? passkeyPresenter : nil)
    }

    private func waitForPhase(_ phase: TwoStepVerificationScreenPhase) async throws {
        let deferred = deferFulfillment(context.observe(\.viewState.phase)) { $0 == phase }
        try await deferred.fulfill()
    }

    /// Loads the report, opens the change flow and submits a number, which is where the factor that
    /// authorizes the change is chosen.
    private func submitNumberForChange() async throws {
        try await waitForPhase(.overview)
        context.send(viewAction: .startChange)
        try context.send(viewAction: .countrySelected(XCTUnwrap(Country.find(isoCode: "US"))))
        context.localPhoneNumber = "4155550143"
        context.send(viewAction: .phoneChanged)
        context.send(viewAction: .continueTapped)
    }

    // MARK: - GUA FORK: a PIN change is authorized by the passkey first

    func testPasskeyHolderChangesPinWithoutBeingAskedForTheCurrentOne() async throws {
        makeViewModel(status: Self.status(hasPin: true, passkeyRegistered: true))

        // No PIN is ever typed here, so reaching the code step means the PIN step was not in the way.
        try await submitNumberForChange()
        try await waitForPhase(.enteringOtp)

        XCTAssertEqual(passkeyPresenter.callCount, 1)
        XCTAssertEqual(identityService.pinChangeStarts.count, 1)
        XCTAssertNil(identityService.pinChangeStarts.first?.currentPin)
        XCTAssertEqual(identityService.pinChangeStarts.first?.stepUpID, "step-up-id")
        XCTAssertTrue(identityService.pinChangeStarts.first?.hasAssertion ?? false)
    }

    func testCancelledPasskeyFallsBackToTheCurrentPinWithoutStartingTheChange() async throws {
        makeViewModel(status: Self.status(hasPin: true, passkeyRegistered: true),
                      passkeyResult: .failure(PasskeyStepUpError.cancelled))

        try await submitNumberForChange()
        try await waitForPhase(.enteringCurrent)

        XCTAssertNil(context.viewState.errorMessage, "A deliberate dismissal is not an error")
        XCTAssertTrue(identityService.pinChangeStarts.isEmpty, "Nothing is sent until a factor is accepted")
    }

    /// A passkey registered too recently is refused by the server with a hold. The PIN underneath is
    /// what that refusal leaves, and it must actually get its turn.
    func testServerRefusedPasskeyFallsBackToTheCurrentPin() async throws {
        makeViewModel(status: Self.status(hasPin: true, passkeyRegistered: true))
        identityService.passkeyPinChangeError = IdentityServiceError.twoFactorCooldown(retryAfterSeconds: 3600)

        try await submitNumberForChange()
        try await waitForPhase(.enteringCurrent)
        XCTAssertEqual(context.viewState.errorMessage, L10n.screenChangePhonePasskeyFallback)
        XCTAssertEqual(passkeyPresenter.callCount, 1)

        context.pin = "123456"
        context.send(viewAction: .pinChanged)
        try await waitForPhase(.enteringOtp)
        XCTAssertEqual(identityService.pinChangeStarts.last?.currentPin, "123456")
        XCTAssertNil(identityService.pinChangeStarts.last?.stepUpID)
    }

    func testAStepUpTheServerWillNotStartFallsBackToTheCurrentPin() async throws {
        makeViewModel(status: Self.status(hasPin: true, passkeyRegistered: true))
        identityService.stepUpError = IdentityServiceError.passkeyStepUpUnavailable

        try await submitNumberForChange()
        try await waitForPhase(.enteringCurrent)

        XCTAssertEqual(context.viewState.errorMessage, L10n.screenChangePhonePasskeyFallback)
        XCTAssertEqual(passkeyPresenter.callCount, 0)
        XCTAssertTrue(identityService.pinChangeStarts.isEmpty)
    }

    /// No connection says nothing about the passkey, so it is not reported as one that was refused,
    /// and the PIN is not offered as though it would fare any better.
    func testAConnectionFailureIsShownAsItIsAndNotAsARefusedPasskey() async throws {
        makeViewModel(status: Self.status(hasPin: true, passkeyRegistered: true))
        identityService.passkeyPinChangeError = IdentityServiceError.transport(URLError(.notConnectedToInternet))

        try await submitNumberForChange()
        try await waitForPhase(.enteringPhone)

        XCTAssertNotNil(context.viewState.errorMessage)
        XCTAssertNotEqual(context.viewState.errorMessage, L10n.screenChangePhonePasskeyFallback)
    }

    func testCancellingWhileThePasskeySheetIsUpSendsNothing() async throws {
        makeViewModel(status: Self.status(hasPin: true, passkeyRegistered: true))
        passkeyPresenter.beforeReturning = { [weak self] in
            self?.context.send(viewAction: .cancelEntry)
        }

        try await submitNumberForChange()
        try await waitForPhase(.overview)
        await Task.yield()

        XCTAssertEqual(passkeyPresenter.callCount, 1)
        XCTAssertTrue(identityService.pinChangeStarts.isEmpty, "No code may be sent for a change that was cancelled")
        XCTAssertEqual(context.viewState.phase, .overview)
    }

    /// The person was never asked for their current PIN on the passkey path, so a failure finishing the
    /// change must not start asking for it.
    func testAFailureAfterThePasskeyWasAcceptedReturnsToTheNewPin() async throws {
        makeViewModel(status: Self.status(hasPin: true, passkeyRegistered: true))
        identityService.completePinChangeError = IdentityServiceError.server(status: 500, message: nil)

        try await submitNumberForChange()
        try await waitForPhase(.enteringOtp)
        context.pin = "123456"
        context.send(viewAction: .pinChanged)
        try await waitForPhase(.enteringNew)
        context.pin = "482915"
        context.send(viewAction: .pinChanged)
        try await waitForPhase(.confirmingNew)
        context.pin = "482915"
        context.send(viewAction: .pinChanged)
        try await waitForPhase(.enteringNew)

        XCTAssertEqual(identityService.completePinChangeCalls, 1)
        XCTAssertNotNil(context.viewState.errorMessage)
    }

    func testPinOnlyAccountIsAskedForTheCurrentPinAndNeverRunsTheCeremony() async throws {
        makeViewModel(status: Self.status(hasPin: true, passkeyRegistered: false))

        try await submitNumberForChange()
        try await waitForPhase(.enteringCurrent)

        XCTAssertEqual(passkeyPresenter.callCount, 0)
        XCTAssertEqual(identityService.stepUpStarts, 0)
    }

    func testAContextThatCannotPresentAPasskeyAsksForTheCurrentPin() async throws {
        makeViewModel(status: Self.status(hasPin: true, passkeyRegistered: true), presentsPasskeys: false)

        try await submitNumberForChange()
        try await waitForPhase(.enteringCurrent)

        XCTAssertEqual(identityService.stepUpStarts, 0)
    }

    private static func status(hasPin: Bool, passkeyRegistered: Bool) -> AccountSecurityStatus {
        AccountSecurityStatus(hasPin: hasPin,
                              passkeyRegistered: passkeyRegistered,
                              preferredFactor: passkeyRegistered ? .passkey : (hasPin ? .pin : .phoneOTP),
                              phoneChangeStepUpFactors: [.passkey, .pin],
                              pinStepUpHoldRemainingSeconds: 0)
    }

    // MARK: - GUA FORK: the overview reads the server's factor report

    /// The overview used to be one of two PIN screens, so an account whose only factor was a
    /// passkey was shown the one that says there is nothing.
    func testPasskeyHolderIsReportedAsHavingAPasskey() async throws {
        makeViewModel(status: Self.status(hasPin: false, passkeyRegistered: true))

        let deferred = deferFulfillment(context.observe(\.viewState.phase)) { $0 == .overview }
        try await deferred.fulfill()

        XCTAssertTrue(context.viewState.passkeyRegistered)
        XCTAssertFalse(context.viewState.hasPin, "The PIN is still on offer as the fallback")
    }

    /// A report that could not be read must not collapse into "no PIN". That fail-open is what
    /// would tell a protected account it has nothing.
    func testUnreadableStatusIsNotReportedAsNoFactor() async throws {
        makeViewModel(status: nil)

        let deferred = deferFulfillment(context.observe(\.viewState.phase)) { $0 == .overview }
        try await deferred.fulfill()

        XCTAssertNil(context.viewState.factors, "An unknown report stays unknown")
        XCTAssertNotNil(context.viewState.errorMessage)
    }

    // MARK: - Phone autofill / paste country-code stripping

    private func enterPhone(_ value: String) {
        context.localPhoneNumber = value
        context.send(viewAction: .phoneChanged)
    }

    func testAutofillInternationalNumberStripsCountryCode() throws {
        try context.send(viewAction: .countrySelected(XCTUnwrap(Country.find(isoCode: "US"))))
        enterPhone("+15551234567")
        XCTAssertTrue(["US", "CA"].contains(context.viewState.selectedCountry.isoCode))
        XCTAssertEqual(context.viewState.localDigits, "5551234567")
        XCTAssertEqual(context.viewState.e164PhoneNumber, "+15551234567")
    }

    func testAutofillFormattedInternationalNumberStrips() throws {
        try context.send(viewAction: .countrySelected(XCTUnwrap(Country.find(isoCode: "US"))))
        enterPhone("+1 (555) 123-4567")
        XCTAssertEqual(context.viewState.localDigits, "5551234567")
        XCTAssertEqual(context.viewState.e164PhoneNumber, "+15551234567")
    }

    func testAutofillBrazilInternationalSwitchesCountry() throws {
        try context.send(viewAction: .countrySelected(XCTUnwrap(Country.find(isoCode: "US"))))
        enterPhone("+5511912345678")
        XCTAssertEqual(context.viewState.selectedCountry.isoCode, "BR")
        XCTAssertEqual(context.viewState.localDigits, "11912345678")
        XCTAssertEqual(context.viewState.e164PhoneNumber, "+5511912345678")
    }

    func testNormalLocalNumberIsNotStripped() throws {
        try context.send(viewAction: .countrySelected(XCTUnwrap(Country.find(isoCode: "US"))))
        enterPhone("5551234567")
        XCTAssertEqual(context.viewState.localDigits, "5551234567")
        XCTAssertEqual(context.viewState.e164PhoneNumber, "+15551234567")
    }
}

// MARK: - Stub

private final class TwoStepVerificationIdentityServiceStub: IdentityServiceClientProtocol {
    /// `nil` stands for a report that could not be read.
    private let status: AccountSecurityStatus?

    init(status: AccountSecurityStatus?) {
        self.status = status
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

    func securityStatus(accessToken: String) async throws -> AccountSecurityStatus {
        guard let status else { throw IdentityServiceError.server(status: 500, message: nil) }
        return status
    }

    func setInitialPin(accessToken: String, userId: String, newPin: String) async throws { }
    struct PinChangeStart {
        let currentPin: String?
        let stepUpID: String?
        let hasAssertion: Bool
    }

    private(set) var pinChangeStarts: [PinChangeStart] = []
    private(set) var stepUpStarts = 0
    private(set) var completePinChangeCalls = 0
    /// Thrown by a start that carries a passkey assertion. A start with the PIN always succeeds.
    var passkeyPinChangeError: Error?
    var stepUpError: Error?
    var completePinChangeError: Error?

    func startPinChange(accessToken: String,
                        phone: String,
                        currentPin: String?,
                        passkeyStepUpID: String?,
                        passkeyAssertion: PasskeyAssertion?) async throws -> String {
        pinChangeStarts.append(PinChangeStart(currentPin: currentPin, stepUpID: passkeyStepUpID, hasAssertion: passkeyAssertion != nil))
        if passkeyAssertion != nil, let passkeyPinChangeError {
            throw passkeyPinChangeError
        }
        return "challenge-id"
    }

    func completePinChange(accessToken: String, challengeId: String, otpCode: String, newPin: String) async throws {
        completePinChangeCalls += 1
        if let completePinChangeError {
            throw completePinChangeError
        }
    }

    func startPasskeyStepUp(accessToken: String) async throws -> PasskeyStepUpOptions {
        stepUpStarts += 1
        if let stepUpError {
            throw stepUpError
        }
        return PasskeyStepUpOptions(stepUpID: "step-up-id", relyingPartyID: "example.com", challenge: Data([1]), allowedCredentialIDs: [])
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
        URL(string: "https://example.com")!
    }
}

private final class TwoStepPasskeyPresenterStub: PasskeyStepUpPresenting {
    private let result: Result<PasskeyAssertion, Error>
    private(set) var callCount = 0
    /// Runs while the sheet would be up, before the result is handed back.
    var beforeReturning: (@MainActor () -> Void)?

    init(result: Result<PasskeyAssertion, Error>) {
        self.result = result
    }

    func assertion(for options: PasskeyStepUpOptions) async throws -> PasskeyAssertion {
        callCount += 1
        if let beforeReturning {
            await beforeReturning()
        }
        return try result.get()
    }
}
