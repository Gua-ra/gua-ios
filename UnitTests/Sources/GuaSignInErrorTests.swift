//
// Copyright Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import XCTest

final class GuaSignInErrorTests: XCTestCase {
    func testAServerThatDoesNotAnswerReadsAsAConnectionProblem() {
        let unreachable: [Error] = [
            GuaSignInError.timedOut,
            ResolverError.transport(URLError(.notConnectedToInternet)),
            ResolverError.transport(URLError(.timedOut)),
            AuthenticationServiceError.invalidHomeserverAddress,
            AuthenticationServiceError.oidcError(.urlFailure)
        ]

        for error in unreachable {
            XCTAssertEqual(GuaSignInError.message(for: error), UntranslatedL10n.guaSignInConnectionFailed, "\(error)")
        }
    }

    func testResolverRefusalsKeepTheirOwnCopy() {
        XCTAssertEqual(GuaSignInError.message(for: ResolverError.invalidPhone), L10n.screenPhoneLoginInvalidNumber)
        XCTAssertEqual(GuaSignInError.message(for: ResolverError.noPlacementAvailable), UntranslatedL10n.guaResolverRegistrationClosed)
    }

    func testClosedRegistrationSaysSo() {
        XCTAssertEqual(GuaSignInError.message(for: AuthenticationServiceError.registrationNotSupported),
                       UntranslatedL10n.guaResolverRegistrationClosed)
    }

    func testNoAuthenticationFailureShowsFoundationsTypeName() {
        let errors: [AuthenticationServiceError] = [
            .oidcError(.unknown), .oidcError(.notSupported), .invalidServer, .invalidCredentials, .invalidWellKnown("x"),
            .slidingSyncNotAvailable, .loginNotSupported, .elementProRequired(serverName: "x"), .accountDeactivated,
            .failedLoggingIn, .sessionTokenRefreshNotSupported, .failedUsingWebCredentials
        ]

        for error in errors {
            let message = GuaSignInError.message(for: error)
            XCTAssertEqual(message, L10n.errorUnknown, "\(error)")
            XCTAssertFalse(message.contains("ElementX"))
        }
    }

    func testABoundedWaitReturnsTheValueOfAFastTask() async {
        let task = Task { 42 }

        let value = await GuaSignInError.value(of: task, within: .seconds(5))

        XCTAssertEqual(value, 42)
    }

    func testABoundedWaitGivesUpOnASlowTaskWithoutWaitingForIt() async {
        let task = Task {
            try? await Task.sleep(for: .seconds(10))
            return 42
        }
        let start = ContinuousClock.now

        let value = await GuaSignInError.value(of: task, within: .milliseconds(100))

        XCTAssertNil(value)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
        task.cancel()
    }

    func testTheResolverRequestGivesUpBeforeURLSessionsDefault() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TimeoutRecordingURLProtocol.self]
        let baseURL = try XCTUnwrap(URL(string: "https://resolver.gua.test"))
        let client = ResolverClient(baseURL: baseURL, session: URLSession(configuration: configuration))

        _ = try? await client.resolve(phoneNumber: "+15551234567")

        let timeout = try XCTUnwrap(TimeoutRecordingURLProtocol.lastTimeoutInterval)
        XCTAssertLessThanOrEqual(timeout, 15)
    }
}

private final class TimeoutRecordingURLProtocol: URLProtocol {
    nonisolated(unsafe) static var lastTimeoutInterval: TimeInterval?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lastTimeoutInterval = request.timeoutInterval
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() { }
}
