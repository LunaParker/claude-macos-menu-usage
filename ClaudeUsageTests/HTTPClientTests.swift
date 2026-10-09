//
//  HTTPClientTests.swift
//  ClaudeUsageTests
//
//  The usage request carries the OAuth bearer token. The shared session used
//  to write every response, with its request headers, into the app's on-disk
//  URL cache; the app's own configuration must never cache anything.
//

import Foundation
import Testing
@testable import ClaudeUsage

@Suite("HTTPClient")
struct HTTPClientTests {

    @Test("a cacheable response fetched with the app's configuration is not cached anywhere")
    func responsesAreNeverCached() async throws {
        let url = StubURLProtocol.uniqueURL()
        StubURLProtocol.stub(url) { _ in
            .init(status: 200, headers: ["Cache-Control": "public, max-age=3600"], body: Data("{}".utf8))
        }
        let configuration = StubURLProtocol.configuration(base: HTTPClient.configuration())
        let client = HTTPClient(session: URLSession(configuration: configuration))
        var request = URLRequest(url: url)
        request.setValue("Bearer sk-ant-oat01-test", forHTTPHeaderField: "Authorization")

        _ = try await client.send(request)

        #expect(configuration.urlCache?.cachedResponse(for: request) == nil)
        #expect(URLCache.shared.cachedResponse(for: request) == nil)
    }

    @Test("the User-Agent carries the version it is given")
    func userAgentCarriesVersion() {
        #expect(HTTPClient.userAgent(version: "2.4").contains("/2.4 "))
        #expect(HTTPClient.userAgent(version: "3.0").contains("/3.0 "))
    }
}

@Suite("RateLimitPolicy")
struct RateLimitPolicyTests {

    private let policy = RateLimitPolicy(defaultBackoff: 300, minimumBackoff: 60)

    @Test("without a usable Retry-After the default backoff applies")
    func defaultBackoff() {
        #expect(policy.cooldown(retryAfter: nil) == 300)
    }

    @Test("a short Retry-After is raised to the minimum")
    func shortRetryAfterIsFloored() {
        #expect(policy.cooldown(retryAfter: 5) == 60)
    }

    @Test("a long Retry-After is honoured")
    func longRetryAfterHonoured() {
        #expect(policy.cooldown(retryAfter: 3600) == 3600)
    }
}
