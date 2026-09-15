//
//  RateLimitCountdownTests.swift
//  ClaudeUsageTests
//
//  Covers `RateLimitCountdown`, the pure formatting behind both the
//  full-screen rate-limited view and the footer line that shows while a
//  429 cooldown is active with a snapshot still on screen.
//

import Foundation
import Testing
@testable import ClaudeUsage

@Suite("RateLimitCountdown")
struct RateLimitCountdownTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: format

    @Test("sub-minute durations render as seconds")
    func secondsOnly() {
        #expect(RateLimitCountdown.format(30) == "30s")
    }

    @Test("durations round up so the countdown never shows 0s before clearing")
    func roundsUp() {
        #expect(RateLimitCountdown.format(0.2) == "1s")
        #expect(RateLimitCountdown.format(30.1) == "31s")
    }

    @Test("minutes and zero-padded seconds above a minute")
    func minutesAndSeconds() {
        #expect(RateLimitCountdown.format(252) == "4m 12s")
        #expect(RateLimitCountdown.format(300) == "5m 00s")
    }

    // MARK: footerText

    @Test("footer text names the remaining cooldown")
    func footerTextWhileCoolingDown() {
        let clearAt = now.addingTimeInterval(252)

        #expect(RateLimitCountdown.footerText(clearAt: clearAt, now: now) == "Rate-limited by Claude · retrying in 4m 12s")
    }

    @Test("footer text disappears once the cooldown has cleared")
    func footerTextAfterClearing() {
        #expect(RateLimitCountdown.footerText(clearAt: now, now: now) == nil)
        #expect(RateLimitCountdown.footerText(clearAt: now.addingTimeInterval(-5), now: now) == nil)
    }
}
