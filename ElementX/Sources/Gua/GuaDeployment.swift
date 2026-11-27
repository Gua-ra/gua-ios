//
// Copyright 2025 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Development endpoints come from the injected `Secrets`, keeping the non-public dev host out of this public repo.
nonisolated enum GuaDeployment {
    case development
    case production
    
    static var current: GuaDeployment {
        #if GUA_DEVELOPMENT
        .development
        #elseif DEBUG
        .development
        #else
        .production
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
    
    var resolverTrustRoots: ResolverTrustRoots {
        switch self {
        case .production:
            return .production
        case .development:
            return ResolverTrustRoots(developmentSecret: Secrets.resolverTrustRoots)
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
    
    /// Not optional and no upstream fallback: registering a pusher hands this host the device's APNs token.
    /// Development uses the production gateway, which knows the development app ids.
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
    
    /// Host for user-facing share links, such as `https://gua.global/u/<handle>`.
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
