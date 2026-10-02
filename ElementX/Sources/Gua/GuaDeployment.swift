//
// Copyright 2025 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation

/// The Gua backend deployment a build talks to: the environment-specific service endpoints, so the
/// rest of the app never hardcodes a host.
///
/// Chosen at build time. Release archives use `.production`; Debug builds, and any build that
/// defines `GUA_DEVELOPMENT`, use `.development`. Production endpoints are committed. Development
/// endpoints come from the injected `Secrets`, so the dev host is never committed.
enum GuaDeployment {
    case development
    case production

    static var current: GuaDeployment {
        #if GUA_DEVELOPMENT
        return .development
        #elseif DEBUG
        return .development
        #else
        return .production
        #endif
    }

    /// Federation resolver base URL, or `nil` when unconfigured. Phone auth needs it to route users to
    /// the correct homeserver.
    var resolverBaseURL: URL? {
        switch self {
        case .production:
            return URL(string: "https://resolver.gua.global")
        case .development:
            return Self.url(from: Secrets.resolverBaseURL)
        }
    }

    /// identity-service base URL (phone/OTP IdP), or `nil` when unconfigured.
    var identityServiceBaseURL: URL? {
        switch self {
        case .production:
            return URL(string: "https://identity.gua.global")
        case .development:
            return Self.url(from: Secrets.identityServiceBaseURL)
        }
    }

    /// Push gateway base URL. Never optional and never upstream's default: registering a pusher hands
    /// the device's APNs token to this host. Both deployments share one gateway until a development
    /// push host exists.
    var pushGatewayBaseURL: URL {
        Self.pushGateway
    }

    private static let pushGateway: URL = "https://push.gua.global"

    /// Default account provider (homeserver host) offered on the login screen, or `nil` when unconfigured.
    var defaultAccountProvider: String? {
        switch self {
        case .production:
            return "gua.global"
        case .development:
            guard let provider = Secrets.defaultAccountProvider, !provider.isEmpty else { return nil }
            return provider
        }
    }

    /// Brand host for user-facing share links (e.g. `https://gua.global/u/<handle>`). Development falls
    /// back to the injected account provider. Always returns a value, so links can be built in every build.
    var linkHost: String {
        switch self {
        case .production:
            return "gua.global"
        case .development:
            guard let provider = defaultAccountProvider, !provider.isEmpty else { return "gua.global" }
            return provider
        }
    }

    private static func url(from raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }
}
