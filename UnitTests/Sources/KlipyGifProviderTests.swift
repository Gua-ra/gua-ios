//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
//

@testable import ElementX
import Foundation
import Testing

final class KlipyGifProviderTests {
    private static let searchResponse = """
    {"result":true,"data":{"data":[
      {"id":8041071659142944,"slug":"hello-hi-662","title":"Hello","type":"gif","blur_preview":"data:image/jpeg;base64,AAAA","tags":["hi"],
       "file":{"hd":{"webp":{"url":"https://static.klipy.com/ii/a/hd.webp","width":498,"height":280,"size":285228},
                     "jpg":{"url":"https://static.klipy.com/ii/a/hd.jpg","width":498,"height":280,"size":19255}},
               "sm":{"webp":{"url":"https://static1.klipy.com/ii/a/sm.webp","width":220,"height":124,"size":64000},
                     "jpg":{"url":"https://static1.klipy.com/ii/a/sm.jpg","width":220,"height":124,"size":6000}}}},
      {"id":1,"type":"ad","content":"<div></div>","width":300,"height":250},
      {"id":2,"slug":"tricky","title":"Off-site","type":"gif",
       "file":{"md":{"webp":{"url":"https://evil.example.com/x.webp","width":1,"height":1,"size":1}}}}
    ],"current_page":2,"per_page":30,"has_next":true}}
    """
    
    init() {
        StickersHTTPStub.reset()
    }
    
    @Test
    func searchSendsTheDocumentedParametersAndNothingElse() async throws {
        StickersHTTPStub.respond(path: "/api/v1/key-123/gifs/search", body: Self.searchResponse)
        let provider = makeProvider(locale: "br")
        
        _ = try await provider.search("oi + tchau", page: 2).get()
        
        let request = try #require(StickersHTTPStub.requests.first)
        let components = try #require(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        #expect(components.host == "api.klipy.com")
        #expect(components.path == "/api/v1/key-123/gifs/search")
        #expect(components.percentEncodedQuery == "q=oi%20%2B%20tchau&page=2&per_page=30&locale=br&content_filter=medium&format_filter=webp,jpg")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Mozilla/5.0")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    }
    
    @Test
    func trendingHasNoQuery() async throws {
        StickersHTTPStub.respond(path: "/api/v1/key-123/gifs/trending", body: Self.searchResponse)
        
        _ = try await makeProvider(locale: nil).trending(page: 1).get()
        
        let url = try #require(StickersHTTPStub.requests.first?.url)
        #expect(url.query() == "page=1&per_page=30&content_filter=medium&format_filter=webp,jpg")
    }
    
    @Test
    func responseKeepsTheProviderOrderAndSkipsAdsAndOffSiteMedia() async throws {
        StickersHTTPStub.respond(path: "/api/v1/key-123/gifs/search", body: Self.searchResponse)
        
        let page = try await makeProvider().search("hello", page: 2).get()
        
        #expect(page.page == 2)
        #expect(page.hasNext)
        #expect(page.items.map(\.id) == ["hello-hi-662"])
        let item = try #require(page.items.first)
        #expect(item.title == "Hello")
        #expect(item.preview?.name == .sm)
        #expect(item.preview?.animated.url.absoluteString == "https://static1.klipy.com/ii/a/sm.webp")
        #expect(item.sendChoice?.rendition == .hd)
        #expect(item.sendChoice?.still.size == 19255)
    }
    
    @Test
    func itemsAreLookedUpBySlug() async throws {
        StickersHTTPStub.respond(path: "/api/v1/key-123/gifs/items", body: Self.searchResponse)
        
        let items = try await makeProvider().items(ids: ["hello-hi-662", "wave-1"]).get()
        
        #expect(items.map(\.id) == ["hello-hi-662"])
        #expect(StickersHTTPStub.requests.first?.url?.query() == "slugs=hello-hi-662,wave-1")
    }
    
    @Test
    func serverErrorsAndBadBodiesFail() async {
        StickersHTTPStub.respond(path: "/api/v1/key-123/gifs/trending", status: 401, body: #"{"result":false}"#)
        guard case .failure(.server(status: 401)) = await makeProvider().trending(page: 1) else {
            Issue.record("Expected the server error")
            return
        }
        
        StickersHTTPStub.respond(path: "/api/v1/key-123/gifs/trending", body: "<html>")
        guard case .failure(.decoding) = await makeProvider().trending(page: 1) else {
            Issue.record("Expected a decoding error")
            return
        }
    }
    
    @Test
    func withoutAKeyNothingIsRequested() async {
        let provider = KlipyGifProvider(configuration: .init(apiKey: " ", proxyHost: nil),
                                        locale: nil,
                                        sessionConfiguration: StickersHTTPStub.sessionConfiguration())
        
        #expect(!provider.isAvailable)
        guard case .failure(.unavailable) = await provider.search("hi", page: 1),
              case .failure(.unavailable) = await provider.data(from: "https://static.klipy.com/a.webp") else {
            Issue.record("Expected the provider to be unavailable")
            return
        }
        #expect(StickersHTTPStub.requests.isEmpty)
    }
    
    @Test
    func mediaIsOnlyFetchedFromKlipyHosts() async {
        StickersHTTPStub.respond(path: "/a.webp", body: "webp")
        let provider = makeProvider()
        
        guard case .success(let data) = await provider.data(from: "https://static.klipy.com/a.webp") else {
            Issue.record("Expected the media")
            return
        }
        #expect(data == Data("webp".utf8))
        
        guard case .failure(.disallowedURL) = await provider.data(from: "https://example.com/a.webp") else {
            Issue.record("Expected the host to be refused")
            return
        }
        #expect(StickersHTTPStub.requests.count == 1)
    }
    
    @Test
    func hostAllowlist() {
        let allowed: [URL] = ["https://api.klipy.com/api/v1/k/gifs/search", "https://static.klipy.com/a.webp", "https://static12.klipy.com/a.jpg",
                              "https://static-eu.klipy.com/a.webp", "https://STATIC.klipy.com:443/a.webp"]
        let refused: [URL] = ["http://static.klipy.com/a.webp", "https://static.klipy.com:8443/a.webp", "https://klipy.com/a.webp",
                              "https://static.klipy.com.evil.com/a.webp", "https://static.evil.klipy.com/a.webp", "https://api.klipy.co/x",
                              "https://evilstatic.klipy.com/a.webp", "https://cdn.klipy.com/a.webp"]
        
        for url in allowed {
            #expect(KlipyGifProvider.isAllowed(url), "\(url)")
        }
        for url in refused {
            #expect(!KlipyGifProvider.isAllowed(url), "\(url)")
        }
    }
    
    @Test
    func redirectsLeavingKlipyAreRefused() async {
        let delegate = KlipySessionDelegate()
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: "https://api.klipy.com/api/v1/k/gifs/trending")
        guard let response = HTTPURLResponse(url: "https://api.klipy.com/api/v1/k/gifs/trending", statusCode: 302, httpVersion: nil, headerFields: nil) else {
            Issue.record("No response")
            return
        }
        
        let inside = await withCheckedContinuation { continuation in
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                newRequest: URLRequest(url: "https://static.klipy.com/a.webp")) { continuation.resume(returning: $0) }
        }
        let outside = await withCheckedContinuation { continuation in
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                newRequest: URLRequest(url: "https://tracker.example.com/a.webp")) { continuation.resume(returning: $0) }
        }
        
        #expect(inside?.url?.host() == "static.klipy.com")
        #expect(outside == nil)
        session.invalidateAndCancel()
    }
    
    @Test
    func proxyEndpointParsing() {
        #expect(GifProxyEndpoint("gif-proxy.gua.global") == GifProxyEndpoint(host: "gif-proxy.gua.global", port: 443))
        #expect(GifProxyEndpoint(" gif-proxy.gua.global:8443 ") == GifProxyEndpoint(host: "gif-proxy.gua.global", port: 8443))
        #expect(GifProxyEndpoint("10.0.0.7:8443") == GifProxyEndpoint(host: "10.0.0.7", port: 8443))
        for invalid in ["", "  ", "https://gif-proxy.gua.global", "gif-proxy.gua.global/path", "user@gif-proxy.gua.global",
                        "gif-proxy.gua.global:0", "gif-proxy.gua.global:70000", "gif-proxy.gua.global:https", ":8443"] {
            #expect(GifProxyEndpoint(invalid) == nil, "\(invalid)")
        }
    }
    
    @Test
    func proxyIsAnHTTPSConnectProxy() {
        let dictionary = GifProxyEndpoint(host: "gif-proxy.gua.global", port: 8443).connectionProxyDictionary
        
        #expect(dictionary["HTTPSEnable"] as? Int == 1)
        #expect(dictionary["HTTPSProxy"] as? String == "gif-proxy.gua.global")
        #expect(dictionary["HTTPSPort"] as? Int == 8443)
    }
    
    @Test
    func emptyConfigurationMeansNoKeyAndNoProxy() {
        let configuration = GifProviderConfiguration(apiKey: "", proxyHost: "")
        
        #expect(configuration.apiKey == nil)
        #expect(configuration.proxy == nil)
        #expect(GifProviderConfiguration(apiKey: " abc ", proxyHost: "p.gua.global").apiKey == "abc")
    }
    
    @Test
    func localeIsTheRegionElseTheLanguage() {
        #expect(KlipyGifProvider.locale(region: "BR", language: "pt-BR") == "br")
        #expect(KlipyGifProvider.locale(region: "419", language: "es") == "es")
        #expect(KlipyGifProvider.locale(region: nil, language: "fr-CA") == "fr")
        #expect(KlipyGifProvider.locale(region: nil, language: nil) == nil)
    }
    
    private func makeProvider(locale: String? = "ca") -> KlipyGifProvider {
        KlipyGifProvider(configuration: .init(apiKey: "key-123", proxyHost: nil),
                         locale: locale,
                         sessionConfiguration: StickersHTTPStub.sessionConfiguration())
    }
}

private extension GifProxyEndpoint {
    init(host: String, port: Int) {
        self.init("\(host):\(port)")! // swiftlint:disable:this force_unwrapping
    }
}
