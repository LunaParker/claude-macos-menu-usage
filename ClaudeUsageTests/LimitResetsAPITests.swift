//
//  LimitResetsAPITests.swift
//  ClaudeUsageTests
//
//  The resets request: its query and headers, and decoding of the
//  `cedar_ember` block the usage endpoint returns for it.
//

import Foundation
import Testing
@testable import ClaudeUsage

@Suite("LimitResetsClient")
struct LimitResetsAPITests {

    /// Shaped like the 2026-11-13 response, with made-up ids and labels.
    static let eligibleBody = """
    {"five_hour": null, "seven_day": {"utilization": 46, "resets_at": "2026-11-17T03:00:00.468470+00:00"},
     "cedar_ember": {"eligible": true, "ineligible_reason": null, "at_limit": false, "exhausted": [],
      "grants": [
       {"id": "weekly-test", "label": "One weekly reset", "resets_total": 1, "resets_left": 1,
        "starts_at": "2026-11-10T21:30:00+00:00", "ends_at": "2026-12-10T22:00:00+00:00",
        "clears": ["seven_day", "seven_day_overage_included"], "paused": false, "usable_now": true,
        "use_requires_limit": false, "percent_used": {"seven_day": 46}, "blocking": [], "arm": null,
        "type": "weekly", "unavailable_reason": null, "gives_back_weekly": false},
       {"id": "fable-test", "label": "One Fable reset", "resets_total": 2, "resets_left": 2,
        "starts_at": "2026-11-09T18:00:00+00:00", "ends_at": "2027-03-09T07:59:00.123456+00:00",
        "clears": ["seven_day_overage_included"], "paused": false, "usable_now": true,
        "use_requires_limit": false, "percent_used": {}, "blocking": [], "arm": null,
        "type": "full", "unavailable_reason": null, "gives_back_weekly": true}
      ],
      "next_grant_id": "weekly-test", "weekly_resets_at": "2026-11-17T03:00:00+00:00",
      "cooldown_until": null, "event_props": {"surface": "claude_code_cli"}, "paused_held": false}}
    """

    @Test("asks for the resets block and identifies as Claude Code, keeping the app's name")
    func requestShape() async throws {
        let (client, url) = makeClient(status: 200, body: "{}")

        _ = try await client.fetchResets(accessToken: "tok-123", cliVersion: "2.1.322")

        let request = try #require(StubURLProtocol.requests(to: url).first)
        let query = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems
        #expect(query == [URLQueryItem(name: "cedar_ember", value: "1"), URLQueryItem(name: "skip_spend", value: "1")])
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-123")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request.value(forHTTPHeaderField: "x-app") == "cli")
        let agent = try #require(request.value(forHTTPHeaderField: "User-Agent"))
        #expect(agent.hasPrefix("claude-cli/2.1.322 (external, cli) MenuBarUsageForClaude/"))
        #expect(agent.hasSuffix("(macOS menu bar)"))
    }

    @Test("decodes the grants of an eligible account")
    func decodesEligibleBlock() async throws {
        let (client, _) = makeClient(status: 200, body: Self.eligibleBody)

        let block = try #require(try await client.fetchResets(accessToken: "tok", cliVersion: "2.1.322"))

        #expect(block.eligible == true)
        #expect(block.grants.map(\.id) == ["weekly-test", "fable-test"])
        let weekly = block.grants[0]
        #expect(weekly.resetsLeft == 1)
        #expect(weekly.clears == ["seven_day", "seven_day_overage_included"])
        #expect(weekly.usableNow == true)
        #expect(weekly.paused == false)
        #expect(weekly.startsAt == Date(timeIntervalSince1970: 1_794_346_200))
        #expect(weekly.endsAt == Date(timeIntervalSince1970: 1_796_940_000))
        let fableEnd = try #require(block.grants[1].endsAt)
        #expect(abs(fableEnd.timeIntervalSince1970 - 1_804_579_140.123) < 0.001)
        #expect(block.grants[1].resetsLeft == 2)
    }

    @Test("an ineligible account keeps the reason")
    func ineligibleBlock() async throws {
        let (client, _) = makeClient(status: 200, body: """
        {"cedar_ember": {"eligible": false, "ineligible_reason": "surface", "grants": []}}
        """)

        let block = try #require(try await client.fetchResets(accessToken: "tok", cliVersion: "2.1.322"))

        #expect(block.eligible == false)
        #expect(block.ineligibleReason == "surface")
        #expect(block.grants.isEmpty)
    }

    @Test("no block, or a null one, is nil", arguments: ["{}", #"{"cedar_ember": null}"#])
    func missingBlock(body: String) async throws {
        let (client, _) = makeClient(status: 200, body: body)

        let block = try await client.fetchResets(accessToken: "tok", cliVersion: "2.1.322")

        #expect(block == nil)
    }

    @Test("a malformed grant is skipped and counted")
    func lenientGrants() async throws {
        let (client, _) = makeClient(status: 200, body: """
        {"cedar_ember": {"eligible": true, "grants": [{"id": 5}, {"id": "ok", "resets_left": 1, "clears": ["seven_day"]}]}}
        """)

        let block = try #require(try await client.fetchResets(accessToken: "tok", cliVersion: "2.1.322"))

        #expect(block.grants.map(\.id) == ["ok"])
        #expect(block.droppedGrants == 1)
    }

    @Test("429 carries the server's Retry-After")
    func rateLimited() async {
        let (client, _) = makeClient(status: 429, headers: ["Retry-After": "120"], body: "")

        let error = await #expect(throws: UsageAPIError.self) {
            try await client.fetchResets(accessToken: "tok", cliVersion: "2.1.322")
        }
        guard case .rateLimited(let retryAfter) = error else {
            Issue.record("expected .rateLimited, got \(String(describing: error))")
            return
        }
        #expect(retryAfter == 120)
    }

    @Test("401 means the token was rejected")
    func rejectedToken() async {
        let (client, _) = makeClient(status: 401, body: "")

        let error = await #expect(throws: UsageAPIError.self) {
            try await client.fetchResets(accessToken: "tok", cliVersion: "2.1.322")
        }
        guard case .unauthorized = error else {
            Issue.record("expected .unauthorized, got \(String(describing: error))")
            return
        }
    }

    private func makeClient(status: Int, headers: [String: String] = [:], body: String) -> (LimitResetsClient, URL) {
        let endpoint = StubURLProtocol.uniqueURL()
        let url = LimitResetsClient.requestURL(endpoint: endpoint)
        StubURLProtocol.stub(url) { _ in .init(status: status, headers: headers, body: Data(body.utf8)) }
        let session = URLSession(configuration: StubURLProtocol.configuration(base: HTTPClient.configuration()))
        return (LimitResetsClient(endpoint: endpoint, http: HTTPClient(session: session)), url)
    }
}
