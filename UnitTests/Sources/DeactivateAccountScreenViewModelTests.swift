//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

@MainActor
struct DeactivateAccountScreenViewModelTests {
    var clientProxy: ClientProxyMock!
    var viewModel: DeactivateAccountScreenViewModelProtocol!
    
    var context: DeactivateAccountScreenViewModelType.Context {
        viewModel.context
    }
    
    init() {
        clientProxy = ClientProxyMock(.init())
        viewModel = DeactivateAccountScreenViewModel(clientProxy: clientProxy, userIndicatorController: UserIndicatorControllerMock())
    }
    
    @Test
    mutating func deactivate() async throws {
        try await validateDeactivate(erasingData: false)
    }
    
    @Test
    mutating func deactivateAndErase() async throws {
        try await validateDeactivate(erasingData: true)
    }
    
    mutating func validateDeactivate(erasingData shouldErase: Bool) async throws {
        let enteredPassword = UUID().uuidString
        
        clientProxy.deactivateAccountPasswordEraseDataClosure = { password, eraseData in
            #expect(password == enteredPassword, "The password should match the user's input.")
            #expect(eraseData == shouldErase, "The erase parameter is unexpected.")
            return .success(())
        }
        
        context.eraseData = shouldErase
        context.password = enteredPassword
        
        #expect(context.alertInfo == nil)
        
        let deferredState = deferFulfillment(context.observe(\.viewState.bindings.alertInfo)) { $0 != nil }
        context.send(viewAction: .deactivate)
        try await deferredState.fulfill()
        
        let confirmationAction = try #require(context.alertInfo?.primaryButton.action,
                                              "Couldn't find the confirmation action.")
        
        let deferredAction = deferFulfillment(viewModel.actionsPublisher) { $0 == .accountDeactivated }
        confirmationAction()
        try await deferredAction.fulfill()
        
        #expect(clientProxy.deactivateAccountPasswordEraseDataCallsCount == 1)
        #expect(clientProxy.deactivateAccountPasswordEraseDataReceivedArguments?.password == enteredPassword)
        #expect(clientProxy.deactivateAccountPasswordEraseDataReceivedArguments?.eraseData == shouldErase)
    }
    
    // MARK: - GUA FORK: reauthentication by phone digest
    
    /// Identity-service never says which number an account is on. It compares what is submitted
    /// with that account's own binding, so the number is asked for and no code exists until it
    /// matches.
    @Test
    mutating func noCodeIsSentUntilTheAccountsNumberIsGiven() async {
        let identityService = DeactivateIdentityServiceStub()
        makeViewModel(identityService: identityService)
        
        context.send(viewAction: .sendReauthCode)
        await Task.yield()
        
        #expect(identityService.startPhones.isEmpty)
        #expect(context.viewState.reauthPhase == .idle)
    }
    
    @Test
    mutating func theNumberTravelsWithBothReauthCalls() async throws {
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
        
        #expect(identityService.startPhones == ["+14155550143"])
        #expect(identityService.verifyCalls.map(\.phone) == ["+14155550143"])
        #expect(identityService.verifyCalls.map(\.operation) == [.deactivate])
    }
    
    /// This screen has no country picker, so a number without its country code would go out as
    /// typed. The server would read it against its own default region and refuse it with the same
    /// neutral sentence a stranger's number earns, having already spent one of the five attempts
    /// the account gets in an hour. It is refused here instead, where the reason can be named.
    @Test
    mutating func aNumberThatIsNotE164NeverCostsAnAttempt() async throws {
        let identityService = DeactivateIdentityServiceStub()
        makeViewModel(identityService: identityService)
        context.phoneNumber = "4155550143"
        
        let refusal = L10n.screenPhoneLoginInvalidNumber
        let deferred = deferFulfillment(context.observe(\.viewState.reauthPhase)) { $0 == .error(refusal) }
        context.send(viewAction: .sendReauthCode)
        try await deferred.fulfill()
        
        #expect(identityService.startPhones.isEmpty)
    }
    
    /// The field declares `.textContentType(.telephoneNumber)`, so one tap on the AutoFill
    /// suggestion fills it with the number exactly as Contacts stores it, brackets and dashes
    /// included. That is the account's own number and the server reads it, so refusing it here
    /// would dead-end the only screen that can deactivate the account. What travels is the resolved
    /// E.164 on both calls, never the punctuation.
    @Test
    mutating func theNumberAutoFillPutsInTheFieldIsSentAsE164() async throws {
        let identityService = DeactivateIdentityServiceStub()
        makeViewModel(identityService: identityService)
        context.phoneNumber = "+1 (415) 555-0143"
        
        var deferred = deferFulfillment(context.observe(\.viewState.reauthPhase)) { $0 == .awaitingCode }
        context.send(viewAction: .sendReauthCode)
        try await deferred.fulfill()
        
        context.otpCode = "123456"
        deferred = deferFulfillment(context.observe(\.viewState.reauthPhase)) { $0 == .verified }
        context.send(viewAction: .verifyReauthCode)
        try await deferred.fulfill()
        
        #expect(identityService.startPhones == ["+14155550143"])
        #expect(identityService.verifyCalls.map(\.phone) == ["+14155550143"])
    }
    
    /// The refusal says only that this is not the number on the account, in the user's language.
    @Test
    mutating func aWrongNumberShowsTheNeutralRefusalAndNothingAboutOtherAccounts() async throws {
        let identityService = DeactivateIdentityServiceStub()
        identityService.startError = IdentityServiceError.reauthPhoneMismatch
        makeViewModel(identityService: identityService)
        context.phoneNumber = "+14155550199"
        
        let refusal = L10n.screenAccountReauthPhoneMismatch
        let deferred = deferFulfillment(context.observe(\.viewState.reauthPhase)) { $0 == .error(refusal) }
        context.send(viewAction: .sendReauthCode)
        try await deferred.fulfill()
    }
    
    private mutating func makeViewModel(identityService: DeactivateIdentityServiceStub) {
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
    func startPasskeyEnrollment(accessToken: String, redirectURI: String?) async throws -> URL {
        URL(string: "https://example.invalid")!
    }
    
    func startPinEnrollment(accessToken: String, redirectURI: String?) async throws -> URL {
        URL(string: "https://example.invalid")!
    }
}
