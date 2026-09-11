//
// Copyright 2025 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation

/// The Gua backend deployment a build talks to. Bundles the environment-specific service endpoints
/// (resolver + identity-service) so the rest of the app never hardcodes a host.
///
/// The active deployment is chosen at **build time**, so the same source ships to every environment:
/// - **Release** archives use `.production`.
/// - **Debug** builds (and any build that defines the `GUA_DEVELOPMENT` compilation condition — e.g. a
///   dev TestFlight scheme) use `.development`.
///
/// Production endpoints are the project's own `gua.global` domain and are safe to commit. **Development**
/// endpoints are read from the injected `Secrets` (the Pkl secrets pipeline), so the non-public dev host
/// is supplied per-machine / per-CI and never committed to this (public) repo.
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

    /// Federation resolver base URL. Gua phone auth requires this to route users to the correct
    /// homeserver/MAS.
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

    /// Push gateway base URL, the host the homeserver hands every notification to on its way to APNs.
    ///
    /// Registering a pusher publishes this URL and the device's APNs token to whoever owns that host.
    /// Upstream ships a default of `matrix.org` and the fork went out still carrying it, so each
    /// install was handing its token to a gateway that is not ours and that cannot deliver for an
    /// app id it does not know. This property exists to make that impossible to repeat, which is why
    /// it is the one endpoint here that is not optional and has no upstream fallback.
    ///
    /// Both deployments currently point at the same gateway because there is no development push
    /// host yet. When one exists it joins the `Secrets` pipeline like the endpoints above, so the
    /// non-public host stays out of this repo. Until then a development build is served by the
    /// production gateway, which knows the development app ids, rather than by anything upstream.
    var pushGatewayBaseURL: URL {
        Self.pushGateway
    }

    private static let pushGateway: URL = "https://push.gua.global"

    /// Default account provider (homeserver host) offered on the login screen, or `nil` when unconfigured.
    /// Production is the committed `gua.global` brand host; development is injected via the `Secrets`
    /// pipeline — the committed placeholder keeps the non-public dev host out of this repo, same as the
    /// service URLs above.
    var defaultAccountProvider: String? {
        switch self {
        case .production:
            return "gua.global"
        case .development:
            guard let provider = Secrets.defaultAccountProvider, !provider.isEmpty else { return nil }
            return provider
        }
    }

    /// Brand host used to build user-facing share links (e.g. `https://gua.global/u/<handle>`).
    /// Production is the committed `gua.global` brand host; development falls back to the injected
    /// dev account provider so links never leak the non-public dev host into this repo, and never
    /// surface a raw homeserver. Always returns a value so share links can be built in every build.
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
