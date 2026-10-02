//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import AuthenticationServices

/// Runs the user-verifying passkey assertion that a privileged operation accepts as its step-up
/// factor. Native rather than web: `POST /security/passkey/stepup/options` returns WebAuthn request
/// options, not a page, and the assertion travels as JSON in the body of the operation.
///
/// Failures stay on the device: the server is never told that a passkey was unavailable, and the
/// caller asks for the next factor.
@MainActor
protocol PasskeyStepUpPresenting {
    /// Presents the system passkey sheet for `options` and returns the assertion to redeem.
    func assertion(for options: PasskeyStepUpOptions) async throws -> PasskeyAssertion
}

enum PasskeyStepUpError: Error {
    /// The ceremony could not be run on this device at all.
    case unavailable
    /// The user dismissed the sheet, or picked no credential.
    case cancelled
    /// The authenticator or the system refused the ceremony.
    case failed(Error)
}

@MainActor
final class PasskeyStepUpPresenter: NSObject, PasskeyStepUpPresenting {
    private let presentationAnchor: ASPresentationAnchor
    /// Retained so the sheet is not torn down early.
    private var controller: ASAuthorizationController?
    private var continuation: CheckedContinuation<PasskeyAssertion, Error>?

    init(presentationAnchor: ASPresentationAnchor) {
        self.presentationAnchor = presentationAnchor
        super.init()
    }

    func assertion(for options: PasskeyStepUpOptions) async throws -> PasskeyAssertion {
        guard !options.relyingPartyID.isEmpty, !options.challenge.isEmpty else {
            throw PasskeyStepUpError.unavailable
        }
        // One ceremony at a time: the server burns the challenge on first presentation.
        guard continuation == nil else { throw PasskeyStepUpError.unavailable }

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: options.relyingPartyID)
        let request = provider.createCredentialAssertionRequest(challenge: options.challenge)
        request.allowedCredentials = options.allowedCredentialIDs.map {
            ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0)
        }
        // The server enforces user verification; this only makes the sheet ask for it.
        request.userVerificationPreference = .required

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            self.controller = controller
            controller.performRequests()
        }
    }

    private func finish(with result: Result<PasskeyAssertion, Error>) {
        controller = nil
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

// MARK: ASAuthorizationControllerDelegate

extension PasskeyStepUpPresenter: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(controller: ASAuthorizationController,
                                             didCompleteWithAuthorization authorization: ASAuthorization) {
        MainActor.assumeIsolated {
            guard let assertion = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
                finish(with: .failure(PasskeyStepUpError.unavailable))
                return
            }
            let encode = { (data: Data) in GuaBase64URL.encode([UInt8](data)) }
            finish(with: .success(PasskeyAssertion(id: encode(assertion.credentialID),
                                                   response: .init(clientDataJSON: encode(assertion.rawClientDataJSON),
                                                                   authenticatorData: encode(assertion.rawAuthenticatorData),
                                                                   signature: encode(assertion.signature),
                                                                   userHandle: assertion.userID.map(encode)))))
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        MainActor.assumeIsolated {
            let code = (error as? ASAuthorizationError)?.code
            if code == .canceled {
                finish(with: .failure(PasskeyStepUpError.cancelled))
            } else if code == .notHandled || code == .notInteractive {
                finish(with: .failure(PasskeyStepUpError.unavailable))
            } else {
                finish(with: .failure(PasskeyStepUpError.failed(error)))
            }
        }
    }
}

// MARK: ASAuthorizationControllerPresentationContextProviding

extension PasskeyStepUpPresenter: ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated { presentationAnchor }
    }
}
