//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// KLIPY's native API. Requests carry no user or Matrix identifier, keep no cookies or cache on disk and, with a
/// proxy configured, reach KLIPY only through it.
final nonisolated class KlipyGifProvider: GifProvider {
    static let providerID = "klipy"
    static let apiHost = "api.klipy.com"
    static let pageSize = 30
    static let userAgent = "Mozilla/5.0"
    
    private let apiKey: String?
    private let locale: String?
    private let session: URLSession
    
    var id: String {
        Self.providerID
    }
    
    var isAvailable: Bool {
        apiKey != nil
    }
    
    init(configuration: GifProviderConfiguration,
         locale: String? = KlipyGifProvider.locale(region: Locale.current.region?.identifier, language: Bundle.main.preferredLocalizations.first),
         sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        apiKey = configuration.apiKey
        self.locale = locale
        
        sessionConfiguration.httpCookieAcceptPolicy = .never
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        if let proxy = configuration.proxy {
            sessionConfiguration.connectionProxyDictionary = proxy.connectionProxyDictionary
        }
        session = URLSession(configuration: sessionConfiguration, delegate: KlipySessionDelegate(), delegateQueue: nil)
    }
    
    deinit {
        session.invalidateAndCancel()
    }
    
    func search(_ query: String, page: Int) async -> Result<GifPage, GifProviderError> {
        await fetchPage(query: query, page: page)
    }
    
    func trending(page: Int) async -> Result<GifPage, GifProviderError> {
        await fetchPage(query: nil, page: page)
    }
    
    func items(ids: [String]) async -> Result<[GifItem], GifProviderError> {
        guard !ids.isEmpty else { return .success([]) }
        guard let apiKey else { return .failure(.unavailable) }
        guard let url = Self.itemsURL(apiKey: apiKey, ids: ids) else { return .failure(.disallowedURL) }
        return await data(from: url).flatMap { data in
            Self.page(from: data, page: 1).map(\.items)
        }
    }
    
    func data(from url: URL) async -> Result<Data, GifProviderError> {
        guard isAvailable else { return .failure(.unavailable) }
        guard Self.isAllowed(url) else { return .failure(.disallowedURL) }
        
        do {
            let (data, response) = try await session.data(from: url)
            guard let response = response as? HTTPURLResponse else { return .failure(.server(status: -1)) }
            guard (200..<300).contains(response.statusCode) else { return .failure(.server(status: response.statusCode)) }
            return .success(data)
        } catch let error as URLError {
            return .failure(error.code == .cancelled ? .cancelled : .network(error))
        } catch {
            return .failure(.cancelled)
        }
    }
    
    static func searchURL(apiKey: String, query: String?, page: Int, locale: String?) -> URL? {
        let endpoint = query == nil ? "trending" : "search"
        var queryItems = [URLQueryItem]()
        if let query {
            queryItems.append(URLQueryItem(name: "q", value: query))
        }
        queryItems += [URLQueryItem(name: "page", value: String(page)),
                       URLQueryItem(name: "per_page", value: String(pageSize))]
        if let locale {
            queryItems.append(URLQueryItem(name: "locale", value: locale))
        }
        queryItems += [URLQueryItem(name: "content_filter", value: "medium"),
                       URLQueryItem(name: "format_filter", value: "webp,jpg")]
        return url(apiKey: apiKey, endpoint: endpoint, queryItems: queryItems)
    }
    
    /// KLIPY looks items up by slug, which is what `GifItem.id` holds.
    static func itemsURL(apiKey: String, ids: [String]) -> URL? {
        url(apiKey: apiKey, endpoint: "items", queryItems: [URLQueryItem(name: "slugs", value: ids.joined(separator: ","))])
    }
    
    /// The device region as a lowercase ISO 3166 code, else the app language.
    static func locale(region: String?, language: String?) -> String? {
        if let region, region.count == 2, region.allSatisfy(\.isLetter) {
            return region.lowercased()
        }
        return language.flatMap { Locale(identifier: $0).language.languageCode?.identifier.lowercased() }
    }
    
    /// Only KLIPY's API and media hosts, over HTTPS on 443.
    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.port == nil || url.port == 443, let host = url.host()?.lowercased() else { return false }
        if host == apiHost {
            return true
        }
        guard host.hasPrefix("static"), host.hasSuffix(".klipy.com") else { return false }
        let label = host.dropFirst("static".count).dropLast(".klipy.com".count)
        return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
    
    private static func url(apiKey: String, endpoint: String, queryItems: [URLQueryItem]) -> URL? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        guard let key = apiKey.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        
        var components = URLComponents()
        components.scheme = "https"
        components.host = apiHost
        components.percentEncodedPath = "/api/v1/\(key)/gifs/\(endpoint)"
        components.queryItems = queryItems
        // URLComponents leaves `+` as is, which servers read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
    
    private func fetchPage(query: String?, page: Int) async -> Result<GifPage, GifProviderError> {
        guard let apiKey else { return .failure(.unavailable) }
        guard let url = Self.searchURL(apiKey: apiKey, query: query, page: page, locale: locale) else { return .failure(.disallowedURL) }
        return await data(from: url).flatMap { Self.page(from: $0, page: page) }
    }
    
    static func page(from data: Data, page: Int) -> Result<GifPage, GifProviderError> {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return .failure(.decoding) }
        let items = response.data.data.compactMap { $0.type == "gif" ? $0.item : nil }
        return .success(GifPage(items: items, page: page, hasNext: response.data.hasNext ?? false))
    }
    
    private struct Response: Decodable {
        let data: Page
    }
    
    private struct Page: Decodable {
        let data: [LossyItem]
        let hasNext: Bool?
        
        enum CodingKeys: String, CodingKey {
            case data
            case hasNext = "has_next"
        }
    }
    
    /// Ads and anything unreadable decode to nothing instead of failing the page.
    private struct LossyItem: Decodable {
        let type: String?
        let item: GifItem?
        
        init(from decoder: Decoder) throws {
            let raw = try? Item(from: decoder)
            type = raw?.type
            item = raw?.gifItem
        }
    }
    
    private struct Item: Decodable {
        let slug: String
        let title: String?
        let type: String
        let file: [String: Formats]
        
        var gifItem: GifItem? {
            var renditions = [GifRendition.Name: GifRendition]()
            for (key, formats) in file {
                guard let name = GifRendition.Name(rawValue: key), let animated = formats.webp?.gifFile else { continue }
                renditions[name] = GifRendition(name: name, animated: animated, still: formats.jpg?.gifFile)
            }
            return renditions.isEmpty ? nil : GifItem(id: slug, title: title ?? "", renditions: renditions)
        }
    }
    
    private struct Formats: Decodable {
        let webp: File?
        let jpg: File?
    }
    
    private struct File: Decodable {
        let url: URL
        let width: Int
        let height: Int
        let size: Int
        
        var gifFile: GifFile? {
            KlipyGifProvider.isAllowed(url) ? GifFile(url: url, width: width, height: height, size: size) : nil
        }
    }
}

/// Refuses any redirect that leaves KLIPY's hosts.
final nonisolated class KlipySessionDelegate: NSObject, URLSessionTaskDelegate {
    // The async variant of this method crashes the Swift 6.3 compiler.
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, KlipyGifProvider.isAllowed(url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
