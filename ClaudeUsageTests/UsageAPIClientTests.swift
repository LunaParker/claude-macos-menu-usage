//
//  UsageAPIClientTests.swift
//  ClaudeUsageTests
//
//  Covers the client's contract with `/api/oauth/usage`: the headers it
//  sends, how each status code maps to an error, and decoding of the
//  endpoint's microsecond timestamps.
//

import Foundation
import Testing
@testable import ClaudeUsage

@Suite("UsageAPIClient")
struct UsageAPIClientTests {

    @Test("sends the bearer token, the OAuth beta header and the app's User-Agent")
    func requestHeaders() async throws {
        let (client, url) = makeClient(status: 200, body: "{}")

        _ = try await client.fetch(accessToken: "tok-123")

        let request = try #require(StubURLProtocol.requests(to: url).first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-123")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("MenuBarUsageForClaude/") == true)
    }

    @Test("reset times with microseconds decode")
    func decodesMicrosecondTimestamps() async throws {
        let (client, _) = makeClient(status: 200, body: """
        {"five_hour": {"utilization": 42.0, "resets_at": "2026-04-11T18:00:01.219127+00:00"}, "seven_day": null}
        """)

        let response = try await client.fetch(accessToken: "tok")

        let resetsAt = try #require(response.fiveHour?.resetsAt)
        #expect(abs(resetsAt.timeIntervalSince1970 - 1_775_930_401.219) < 0.001)
        #expect(response.fiveHour?.utilization == 42)
    }

    @Test("401 and 403 both mean the token was rejected", arguments: [401, 403])
    func rejectedToken(status: Int) async {
        let (client, _) = makeClient(status: status, body: "")

        let error = await #expect(throws: UsageAPIError.self) {
            try await client.fetch(accessToken: "tok")
        }
        guard case .unauthorized = error else {
            Issue.record("expected .unauthorized, got \(String(describing: error))")
            return
        }
    }

    @Test("429 carries the server's Retry-After")
    func rateLimited() async {
        let (client, _) = makeClient(status: 429, headers: ["Retry-After": "120"], body: "")

        let error = await #expect(throws: UsageAPIError.self) {
            try await client.fetch(accessToken: "tok")
        }
        guard case .rateLimited(let retryAfter) = error else {
            Issue.record("expected .rateLimited, got \(String(describing: error))")
            return
        }
        #expect(retryAfter == 120)
    }

    @Test("other status codes surface as HTTP errors")
    func serverError() async {
        let (client, _) = makeClient(status: 503, body: "")

        let error = await #expect(throws: UsageAPIError.self) {
            try await client.fetch(accessToken: "tok")
        }
        guard case .http(503) = error else {
            Issue.record("expected .http(503), got \(String(describing: error))")
            return
        }
    }

    @Test("an unparseable body is a decoding error")
    func malformedBody() async {
        let (client, _) = makeClient(status: 200, body: "<html>")

        let error = await #expect(throws: UsageAPIError.self) {
            try await client.fetch(accessToken: "tok")
        }
        guard case .decoding = error else {
            Issue.record("expected .decoding, got \(String(describing: error))")
            return
        }
    }

    private func makeClient(status: Int, headers: [String: String] = [:], body: String) -> (UsageAPIClient, URL) {
        let url = StubURLProtocol.uniqueURL()
        StubURLProtocol.stub(url) { _ in .init(status: status, headers: headers, body: Data(body.utf8)) }
        let session = URLSession(configuration: StubURLProtocol.configuration(base: HTTPClient.configuration()))
        return (UsageAPIClient(endpoint: url, http: HTTPClient(session: session)), url)
    }
}
