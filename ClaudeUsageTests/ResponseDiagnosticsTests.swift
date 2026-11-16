//
//  ResponseDiagnosticsTests.swift
//  ClaudeUsageTests
//
//  The one-line summary logged for an error response: status, allowlisted
//  headers and the body's error, capped so a large page can't flood the log.
//

import Foundation
import Testing
@testable import ClaudeUsage

@Suite("ResponseDiagnostics")
struct ResponseDiagnosticsTests {

    @Test("names the allowlisted headers and the error envelope's type and message")
    func rateLimitEnvelope() {
        let response = makeResponse(status: 429, headers: [
            "Retry-After": "3600",
            "request-id": "req_011abc",
            "x-should-retry": "true",
            "anthropic-ratelimit-unified-status": "rejected",
        ])
        let body = #"{"type":"error","error":{"type":"rate_limit_error","message":"Rate limited. Please try again later."}}"#

        let line = ResponseDiagnostics.summary(of: response, body: Data(body.utf8), endpoint: "usage")

        #expect(line == "HTTP 429 from usage — retry-after 3600, request-id req_011abc, x-should-retry true, anthropic-ratelimit-unified-status rejected; rate_limit_error: Rate limited. Please try again later.")
    }

    @Test("leaves out headers that aren't on the allowlist")
    func headerAllowlist() {
        let response = makeResponse(status: 401, headers: [
            "Set-Cookie": "session=secret",
            "Authorization": "Bearer secret",
            "request-id": "req_1",
        ])

        let line = ResponseDiagnostics.summary(of: response, body: Data(), endpoint: "usage")

        #expect(line == "HTTP 401 from usage — request-id req_1")
        #expect(!line.contains("secret"))
    }

    @Test("quotes a body that isn't an error envelope, on one line and capped at 200 characters")
    func plainBody() {
        let response = makeResponse(status: 503, headers: [:])
        let body = "<html>\n  <body>" + String(repeating: "x", count: 300) + "</body>\n</html>"

        let line = ResponseDiagnostics.summary(of: response, body: Data(body.utf8), endpoint: "limit resets")

        let quoted = "<html> <body>" + String(repeating: "x", count: 186) + "…"
        #expect(line == "HTTP 503 from limit resets; body \"\(quoted)\"")
    }

    @Test("caps a long error message at 200 characters")
    func longMessage() {
        let response = makeResponse(status: 403, headers: [:])
        let message = String(repeating: "m", count: 250)
        let body = #"{"type":"error","error":{"type":"permission_error","message":"\#(message)"}}"#

        let line = ResponseDiagnostics.summary(of: response, body: Data(body.utf8), endpoint: "usage")

        #expect(line == "HTTP 403 from usage; permission_error: \(String(repeating: "m", count: 199))…")
    }

    @Test("is just the status when there's nothing else to say")
    func bare() {
        let line = ResponseDiagnostics.summary(of: makeResponse(status: 500, headers: [:]), body: Data(), endpoint: "usage")

        #expect(line == "HTTP 500 from usage")
    }
}

private func makeResponse(status: Int, headers: [String: String]) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, statusCode: status, httpVersion: "HTTP/2", headerFields: headers)!
}
