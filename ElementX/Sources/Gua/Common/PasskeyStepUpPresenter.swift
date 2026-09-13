//
// Copyright 2025 Gua. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import AuthenticationServices

/// GUA FORK: runs the user-verifying passkey assertion that a privileged operation accepts as its
/// step-up factor, currently the phone-number change.
///
/// Native rather than web, unlike ``PasskeyEnrollmentPresenter``: `POST
/// /security/passkey/stepup/options` hands back WebAuthn request options rather than a page, and
/// the assertion has to come back as JSON so it can travel in the body of the operation being
/// stepped up.
///
/// Everything this type can report is about THIS DEVICE, and none of it is ever sent anywhere. A
/// failure here makes the caller ask for the next factor down, which is the PIN; the server is not
/// told that a passkey was unavailable, because that claim costs an attacker nothing and could only
/// ever be a request for the weaker factor.
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
    /// Retained for the lifetime of the ceremony so the sheet is not torn down early.
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
        // One ceremony at a time. The challenge behind it is burned by the server on first
        // presentation, accepted or refused, so a second concurrent attempt could only spend a
        // challenge that is already gone.
        guard continuation == nil else { throw PasskeyStepUpError.unavailable }

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: options.relyingPartyID)
        let request = provider.createCredentialAssertionRequest(challenge: options.challenge)
        request.allowedCredentials = options.allowedCredentialIDs.map {
            ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0)
        }
        // The step-up bar, restated on the client so the sheet asks for a real user verification
        // rather than only for possession of an unlocked device. The server checks it again on the
        // authenticator data it is handed and refuses the assertion if it did not happen, so this
        // is the prompt, not the enforcement.
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
