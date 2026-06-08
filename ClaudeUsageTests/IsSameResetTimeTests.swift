//
//  IsSameResetTimeTests.swift
//  ClaudeUsageTests
//
//  Covers `NotificationManager.isSameResetTime`. The 2-second tolerance
//  is load-bearing: the usage endpoint jitters fractional seconds for the
//  same session window, and treating each jitter as a "new window" used
//  to wipe `firedThresholds` and cause repeated notifications.
//

import Foundation
import Testing
@testable import ClaudeUsage

@Suite("NotificationManager.isSameResetTime")
struct IsSameResetTimeTests {

    // MARK: Nil pairings

    @Test("both nil compare equal")
    func bothNil() {
        #expect(NotificationManager.isSameResetTime(nil, nil))
    }

    @Test("nil and a date compare unequal (either order)")
    func nilAndDate() {
        let d = Date()
        #expect(NotificationManager.isSameResetTime(nil, d) == false)
        #expect(NotificationManager.isSameResetTime(d, nil) == false)
    }

    // MARK: Tolerance window

    @Test("identical dates compare equal")
    func identical() {
        let d = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(NotificationManager.isSameResetTime(d, d))
    }

    @Test("sub-second jitter within tolerance — the case that motivated this function")
    func subSecondJitter() {
        let a = Date(timeIntervalSince1970: 1_700_000_000.93)
        let b = Date(timeIntervalSince1970: 1_700_000_001.07)
        #expect(NotificationManager.isSameResetTime(a, b))
    }

    @Test("just under 2 seconds compares equal")
    func justUnderTolerance() {
        let a = Date(timeIntervalSince1970: 1_700_000_000)
        let b = Date(timeIntervalSince1970: 1_700_000_001.999)
        #expect(NotificationManager.isSameResetTime(a, b))
    }

    @Test("exactly 2 seconds is the boundary — treated as different windows")
    func atTolerance() {
        let a = Date(timeIntervalSince1970: 1_700_000_000)
        let b = Date(timeIntervalSince1970: 1_700_000_002)
        #expect(NotificationManager.isSameResetTime(a, b) == false)
    }

    @Test("comfortably outside tolerance compares unequal")
    func outsideTolerance() {
        let a = Date(timeIntervalSince1970: 1_700_000_000)
        let b = Date(timeIntervalSince1970: 1_700_000_010)
        #expect(NotificationManager.isSameResetTime(a, b) == false)
    }

    @Test("a real 5-hour session-window rotation is detected")
    func fiveHourRotation() {
        let a = Date(timeIntervalSince1970: 1_700_000_000)
        let b = a.addingTimeInterval(5 * 60 * 60)
        #expect(NotificationManager.isSameResetTime(a, b) == false)
    }
}
