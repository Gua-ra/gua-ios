//
// Copyright 2025 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

import Foundation

/// Development endpoints come from the injected `Secrets`, so the dev host is never committed.
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

    var resolverBaseURL: URL? {
        switch self {
        case .production:
            return URL(string: "https://resolver.gua.global")
        case .development:
            return Self.url(from: Secrets.resolverBaseURL)
        }
    }

    var identityServiceBaseURL: URL? {
        switch self {
        case .production:
            return URL(string: "https://identity.gua.global")
        case .development:
            return Self.url(from: Secrets.identityServiceBaseURL)
        }
    }

    /// Never optional and never upstream's default: registering a pusher hands the device's APNs token to this host.
    var pushGatewayBaseURL: URL {
        Self.pushGateway
    }

    private static let pushGateway: URL = "https://push.gua.global"

    var defaultAccountProvider: String? {
        switch self {
        case .production:
            return "gua.global"
        case .development:
            guard let provider = Secrets.defaultAccountProvider, !provider.isEmpty else { return nil }
            return provider
        }
    }

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
