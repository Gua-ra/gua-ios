//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

nonisolated struct GifProviderConfiguration: Hashable, Sendable {
    let apiKey: String?
    let proxy: GifProxyEndpoint?
    
    static var bundled: GifProviderConfiguration {
        GifProviderConfiguration(apiKey: Secrets.klipyAPIKey, proxyHost: Secrets.gifProxyHost)
    }
    
    init(apiKey: String?, proxyHost: String?) {
        let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = apiKey?.isEmpty == false ? apiKey : nil
        proxy = proxyHost.flatMap(GifProxyEndpoint.init)
    }
}

nonisolated struct GifProxyEndpoint: Hashable, Sendable {
    static let defaultPort = 443
    
    let host: String
    let port: Int
    
    init?(_ value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("/"), !value.contains("@"),
              let components = URLComponents(string: "//\(value)"),
              let host = components.host, !host.isEmpty else {
            return nil
        }
        let port = components.port ?? Self.defaultPort
        guard (1...65535).contains(port) else { return nil }
        
        self.host = host
        self.port = port
    }
    
    /// `URLSessionConfiguration.connectionProxyDictionary`. The `kCFNetworkProxiesHTTPS*` constants are macOS only, so
    /// their values are spelled out; iOS honours them.
    var connectionProxyDictionary: [AnyHashable: Any] {
        ["HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port]
    }
}
