//
// Copyright 2022-2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import XCTest

@MainActor
class DeactivateAccountScreenViewModelTests: XCTestCase {
    var clientProxy: ClientProxyMock!
    var viewModel: DeactivateAccountScreenViewModelProtocol!
    
    var context: DeactivateAccountScreenViewModelType.Context {
        viewModel.context
    }
    
    override func setUpWithError() throws {
        clientProxy = ClientProxyMock(.init())
        viewModel = DeactivateAccountScreenViewModel(clientProxy: clientProxy, userIndicatorController: UserIndicatorControllerMock())
    }
    
    func testDeactivate() async throws {
        try await validateDeactivate(erasingData: false)
    }
    
    func testDeactivateAndErase() async throws {
        try await validateDeactivate(erasingData: true)
    }
    
    func validateDeactivate(erasingData shouldErase: Bool) async throws {
        let enteredPassword = UUID().uuidString
        
        clientProxy.deactivateAccountPasswordEraseDataClosure = { [weak self] password, eraseData in
            guard let self else { return .failure(.sdkError(ClientProxyMockError.generic)) }
            
            if clientProxy.deactivateAccountPasswordEraseDataCallsCount == 1 {
                if password != nil {
                    XCTFail("The password shouldn't be sent first time round.")
                }
                if eraseData != shouldErase {
                    XCTFail("The erase parameter is unexpected.")
                }
                return .failure(.sdkError(ClientProxyMockError.generic))
            } else {
                if password != enteredPassword {
                    XCTFail("The password should match the user's input on the second call.")
                }
                if eraseData != shouldErase {
                    XCTFail("The erase parameter is unexpected.")
                }
                return .success(())
            }
        }
        
        context.eraseData = shouldErase
        context.password = enteredPassword
        
        XCTAssertNil(context.alertInfo)
        
        let deferredState = deferFulfillment(context.observe(\.viewState.bindings.alertInfo)) { $0 != nil }
        context.send(viewAction: .deactivate)
        try await deferredState.fulfill()
        
        guard let confirmationAction = context.alertInfo?.primaryButton.action else {
            XCTFail("Couldn't find the confirmation action.")
            return
        }
        
        let deferredAction = deferFulfillment(viewModel.actionsPublisher) { $0 == .accountDeactivated }
        confirmationAction()
        try await deferredAction.fulfill()
        
        XCTAssertEqual(clientProxy.deactivateAccountPasswordEraseDataCallsCount, 2)
        XCTAssertEqual(clientProxy.deactivateAccountPasswordEraseDataReceivedArguments?.password, enteredPassword)
        XCTAssertEqual(clientProxy.deactivateAccountPasswordEraseDataReceivedArguments?.eraseData, shouldErase)
    }
    
    // MARK: - GUA FORK: reauthentication by phone digest
    
    /// Identity-service never says which number an account is on. It compares what is submitted
    /// with that account's own binding, so the number is asked for and no code exists until it
    /// matches.
    func testNoCodeIsSentUntilTheAccountsNumberIsGiven() async {
        let identityService = DeactivateIdentityServiceStub()
        makeViewModel(identityService: identityService)
        
        context.send(viewAction: .sendReauthCode)
        await Task.yield()
        
        XCTAssertTrue(identityService.startPhones.isEmpty)
        XCTAssertEqual(context.viewState.reauthPhase, .idle)
    }
    
    func testTheNumberTravelsWithBothReauthCalls() async throws {
        let identityService = DeactivateIdentityServiceStub()
        makeViewModel(identityService: identityService)
        context.phoneNumber = "+14155550143"
        
        var deferred = deferFulfillment(context.observe(\.viewState.reauthPhase)) { $0 == .awaitingCode }
        context.send(viewAction: .sendReauthCode)
        try await deferred.fulfill()
        
        context.otpCode = "123456"
        deferred = deferFulfillment(context.observe(\.viewState.reauthPhase)) { $0 == .verified }
        context.send(viewAction: .verifyReauthCode)
        try await deferred.fulfill()
        
        XCTAssertEqual(identityService.startPhones, ["+14155550143"])
        XCTAssertEqual(identityService.verifyCalls.map(\.phone), ["+14155550143"])
        XCTAssertEqual(identityService.verifyCalls.map(\.operation), [.deactivate])
    }
    
    /// The refusal is the server's, and it says only that this is not the number on the account.
    func testAWrongNumberShowsTheServersRefusalAndNothingAboutOtherAccounts() async throws {
        let identityService = DeactivateIdentityServiceStub()
        let refusal = "That is not the number on your account."
        identityService.startError = IdentityServiceError.reauthPhoneMismatch(message: refusal)
        makeViewModel(identityService: identityService)
        context.phoneNumber = "+14155550199"
        
        let deferred = deferFulfillment(context.observe(\.viewState.reauthPhase)) { $0 == .error(refusal) }
        context.send(viewAction: .sendReauthCode)
        try await deferred.fulfill()
    }
    
    private func makeViewModel(identityService: DeactivateIdentityServiceStub) {
        clientProxy.accessToken = "access-token"
        viewModel = DeactivateAccountScreenViewModel(clientProxy: clientProxy,
                                                     userIndicatorController: UserIndicatorControllerMock(),
                                                     identityServiceClient: identityService)
    }
}

// MARK: - Stub

/// GUA FORK: identity-service as this screen sees it, which is the two reauth calls and the
/// deactivation they authorize.
@MainActor
private final class DeactivateIdentityServiceStub: IdentityServiceClientProtocol {
    struct VerifyCall {
        let phone: String
        let operation: ReauthOperation
    }
    
    var startError: Error?
    private(set) var startPhones: [String] = []
    private(set) var verifyCalls: [VerifyCall] = []
    
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
    
    func lookupContacts(accessToken: String, phones: [String]) async throws -> [ContactMatch] {
        []
    }
    
    func deactivateAccount(accessToken: String, reauthToken: String, eraseData: Bool) async throws { }
    func resetIdentityCredentials(accessToken: String, reauthToken: String) async throws -> IdentityResetCredentials {
        IdentityResetCredentials(userId: "", password: "")
    }
    
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
