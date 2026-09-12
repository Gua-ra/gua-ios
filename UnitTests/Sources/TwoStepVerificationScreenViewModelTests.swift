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

    private func makeViewModel(status: AccountSecurityStatus?) {
        identityService = TwoStepVerificationIdentityServiceStub(status: status)
        let clientProxy = ClientProxyMock(.init())
        clientProxy.accessToken = "access-token"
        viewModel = TwoStepVerificationScreenViewModel(clientProxy: clientProxy,
                                                       identityServiceClient: identityService,
                                                       userIndicatorController: UserIndicatorControllerMock())
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
    func startPinChange(accessToken: String, phone: String, currentPin: String) async throws -> String {
        ""
    }

    func completePinChange(accessToken: String, challengeId: String, otpCode: String, newPin: String) async throws { }
    func startPasskeyStepUp(accessToken: String) async throws -> PasskeyStepUpOptions {
        PasskeyStepUpOptions(stepUpID: "", relyingPartyID: "", challenge: Data(), allowedCredentialIDs: [])
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
