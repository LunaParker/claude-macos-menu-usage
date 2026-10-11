//
//  UsagePaceTests.swift
//  ClaudeUsageTests
//
//  UsagePace turns a bar and the clock into the share of its window that
//  has passed and a verdict: on pace, or the time usage reaches 100% at a
//  straight-line rate from the window's start. A window too young to
//  extrapolate, or a bar already full, gets no verdict.
//

import Foundation
import Testing
@testable import ClaudeUsage

@Suite("UsagePace")
struct UsagePaceTests {

    private let now = TestSnapshots.now

    @Test("the elapsed share counts from 5 h (session) or 7 d (weekly) before the reset")
    func elapsedShare() throws {
        let session = try #require(UsagePace(bar: bar(.session, 0.1, resetsIn: 3 * 3600), now: now))
        let weekly = try #require(UsagePace(bar: bar(.weekly, 0.1, resetsIn: 3 * 86_400), now: now))
        let fable = try #require(UsagePace(bar: bar(.scopedWeekly, 0.1, resetsIn: 3 * 86_400), now: now))

        #expect(abs(session.elapsed - 0.4) < 0.0001)
        #expect(abs(weekly.elapsed - 4.0 / 7.0) < 0.0001)
        #expect(abs(fable.elapsed - 4.0 / 7.0) < 0.0001)
    }

    @Test("no reset time, or a reset already passed, gives no pace")
    func noWindowNoPace() {
        #expect(UsagePace(bar: bar(.session, 0.5, resetsIn: nil), now: now) == nil)
        #expect(UsagePace(bar: bar(.session, 0.5, resetsIn: -60), now: now) == nil)
    }

    @Test("a window less than 5% old is shown but not judged")
    func tooEarlyForAVerdict() throws {
        let pace = try #require(UsagePace(bar: bar(.session, 0.2, resetsIn: 5 * 3600 - 10 * 60), now: now))

        #expect(abs(pace.elapsed - 10.0 / 300.0) < 0.0001)
        #expect(pace.verdict == nil)
    }

    @Test("usage at or under the elapsed share is on pace")
    func onPace() throws {
        #expect(try #require(UsagePace(bar: bar(.session, 0.3, resetsIn: 3 * 3600), now: now)).verdict == .onPace)
        #expect(try #require(UsagePace(bar: bar(.session, 0.4, resetsIn: 3 * 3600), now: now)).verdict == .onPace)
        #expect(try #require(UsagePace(bar: bar(.weekly, 0.0, resetsIn: 3 * 86_400), now: now)).verdict == .onPace)
    }

    @Test("usage ahead of the elapsed share projects when it reaches 100%")
    func projectsFull() throws {
        // Two hours in at 50%: full two hours from now.
        let session = try #require(UsagePace(bar: bar(.session, 0.5, resetsIn: 3 * 3600), now: now))
        #expect(session.verdict == .full(at: now.addingTimeInterval(2 * 3600)))

        // Four days in at 80%: full after five days, one day from now.
        let weekly = try #require(UsagePace(bar: bar(.weekly, 0.8, resetsIn: 3 * 86_400), now: now))
        #expect(weekly.verdict == .full(at: now.addingTimeInterval(86_400)))
    }

    @Test("a full bar has nothing left to project")
    func fullBarHasNoVerdict() throws {
        let pace = try #require(UsagePace(bar: bar(.session, 1.0, resetsIn: 3 * 3600), now: now))

        #expect(pace.verdict == nil)
    }

    private func bar(_ kind: UsageSnapshot.Bar.Kind, _ fraction: Double, resetsIn: TimeInterval?) -> UsageSnapshot.Bar {
        TestSnapshots.bar(kind, "Bar", fraction, resetsIn.map { now.addingTimeInterval($0) })
    }
}

@Suite("UsagePace verdict label")
struct UsagePaceLabelTests {

    private let now = TestSnapshots.now
    private let locale = Locale(identifier: "en_US")
    private let timeZone = TimeZone(identifier: "America/Toronto")!

    @Test("on pace says so")
    func onPace() {
        #expect(UsagePace.Verdict.onPace.label(now: now, locale: locale, timeZone: timeZone) == "On pace")
    }

    @Test("a projection within a day gives the time")
    func withinADay() {
        let verdict = UsagePace.Verdict.full(at: now.addingTimeInterval(2 * 3600))

        #expect(verdict.label(now: now, locale: locale, timeZone: timeZone) == "100% by 5:00\u{202F}AM")
    }

    @Test("a projection on another calendar day names it, even within 24 hours")
    func nextDayWithin24Hours() {
        let verdict = UsagePace.Verdict.full(at: now.addingTimeInterval(23 * 3600))

        #expect(verdict.label(now: now, locale: locale, timeZone: timeZone) == "100% by Sat 2:00\u{202F}AM")
    }

    @Test("a projection further out adds the short weekday")
    func beyondADay() {
        let verdict = UsagePace.Verdict.full(at: now.addingTimeInterval(2 * 86_400 + 3600))

        #expect(verdict.label(now: now, locale: locale, timeZone: timeZone) == "100% by Sun 4:00\u{202F}AM")
    }
}
