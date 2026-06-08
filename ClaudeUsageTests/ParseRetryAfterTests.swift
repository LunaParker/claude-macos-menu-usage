//
//  ParseRetryAfterTests.swift
//  ClaudeUsageTests
//
//  Covers `UsageAPIClient.parseRetryAfter`. The function has four code
//  paths (nil/empty, integer-seconds, HTTP-date, fallback) plus a "treat
//  sub-1-second values as nil" rule that prevents a stray `Retry-After: 0`
//  from disabling the rate-limit cooldown.
//

import Foundation
import Testing
@testable import ClaudeUsage

@Suite("UsageAPIClient.parseRetryAfter")
struct ParseRetryAfterTests {

    // MARK: Empty / missing input

    @Test("nil header returns nil")
    func nilHeader() {
        #expect(UsageAPIClient.parseRetryAfter(nil) == nil)
    }

    @Test("empty string returns nil")
    func emptyString() {
        #expect(UsageAPIClient.parseRetryAfter("") == nil)
    }

    @Test("whitespace-only string returns nil")
    func whitespaceOnly() {
        #expect(UsageAPIClient.parseRetryAfter("   ") == nil)
    }

    // MARK: Integer-seconds form

    @Test("integer seconds parsed verbatim")
    func integerSeconds() {
        #expect(UsageAPIClient.parseRetryAfter("120") == 120)
    }

    @Test("integer seconds with surrounding whitespace trimmed")
    func integerSecondsTrimmed() {
        #expect(UsageAPIClient.parseRetryAfter("  300  ") == 300)
    }

    @Test("fractional seconds parsed")
    func fractionalSeconds() {
        #expect(UsageAPIClient.parseRetryAfter("30.5") == 30.5)
    }

    // MARK: Sub-1-second clamp

    // The clamp is the load-bearing detail: without it a stray
    // `Retry-After: 0` would translate to "no cooldown" and the
    // background poll would hammer the 429-ing endpoint once per minute.
    @Test("zero seconds returns nil so caller falls back to default backoff")
    func zeroSecondsClamped() {
        #expect(UsageAPIClient.parseRetryAfter("0") == nil)
    }

    @Test("sub-second fractional values return nil")
    func subSecondClamped() {
        #expect(UsageAPIClient.parseRetryAfter("0.5") == nil)
    }

    @Test("exactly 1 second is honoured (the boundary)")
    func oneSecondHonoured() {
        #expect(UsageAPIClient.parseRetryAfter("1") == 1)
    }

    // MARK: Unparsable

    @Test("non-numeric, non-date garbage returns nil")
    func garbageReturnsNil() {
        #expect(UsageAPIClient.parseRetryAfter("soon") == nil)
    }

    // MARK: HTTP-date form

    @Test("HTTP-date in the future parses to a positive interval")
    func httpDateInFuture() {
        let future = Date().addingTimeInterval(600) // 10 min ahead
        let header = Self.httpDateFormatter.string(from: future)
        let result = UsageAPIClient.parseRetryAfter(header)
        // Allow a couple of seconds of slack for test-runtime drift.
        #expect(result != nil)
        if let result {
            #expect(result > 590 && result < 610)
        }
    }

    @Test("HTTP-date in the past returns nil")
    func httpDateInPast() {
        let past = Date().addingTimeInterval(-3600) // 1 h ago
        let header = Self.httpDateFormatter.string(from: past)
        #expect(UsageAPIClient.parseRetryAfter(header) == nil)
    }

    // Mirrors the formatter the implementation uses, so the round-trip
    // is faithful.
    private static let httpDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()
}
