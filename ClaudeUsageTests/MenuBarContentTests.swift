//
//  MenuBarContentTests.swift
//  ClaudeUsageTests
//
//  MenuBarContent decides what sits beside the gauge: the chosen quota's
//  percentage, a warning triangle for a quota near its limit that isn't the
//  one shown, or, while any quota is used up, the time until it resets.
//

import Foundation
import Testing
@testable import ClaudeUsage

@Suite("MenuBarContent")
struct MenuBarContentTests {

    private let now = TestSnapshots.now

    @Test("without a snapshot: the idle gauge, no text, no warning")
    func noSnapshot() {
        let content = MenuBarContent(snapshot: nil, metric: .highest, now: now)

        #expect(content.symbolName == "gauge.with.dots.needle.bottom.50percent")
        #expect(content.text == nil)
        #expect(content.showsWarning == false)
        #expect(content.accessibilityLabel == "Menu Bar Usage for Claude")
    }

    @Test("off shows the icon alone")
    func offShowsNothing() {
        let content = MenuBarContent(snapshot: .snapshot(session: 0.55, weekly: 0.3), metric: .off, now: now)

        #expect(content.text == nil)
        #expect(content.showsWarning == false)
    }

    @Test("each metric shows its own bar", arguments: [
        (MenuBarMetric.session, "55%"), (.weekly, "30%"), (.scopedWeekly, "80%"),
    ])
    func metricShowsItsBar(metric: MenuBarMetric, text: String) {
        let snapshot = UsageSnapshot.snapshot(session: 0.55, weekly: 0.3, fable: 0.8)

        #expect(MenuBarContent(snapshot: snapshot, metric: metric, now: now).text == text)
    }

    @Test("highest shows the fullest bar")
    func highestPicksTheFullest() {
        #expect(MenuBarContent(snapshot: .snapshot(session: 0.55, weekly: 0.3, fable: 0.8), metric: .highest, now: now).text == "80%")
        #expect(MenuBarContent(snapshot: .snapshot(session: 0.55, weekly: 0.3), metric: .highest, now: now).text == "55%")
        #expect(MenuBarContent(snapshot: .snapshot(session: 0.2, weekly: 0.6), metric: .highest, now: now).text == "60%")
    }

    @Test("the model metric falls back to the highest bar on a plan without one")
    func scopedFallsBackToHighest() {
        let content = MenuBarContent(snapshot: .snapshot(session: 0.55, weekly: 0.3), metric: .scopedWeekly, now: now)

        #expect(content.text == "55%")
    }

    @Test("the session metric falls back to the highest bar on a plan without a session")
    func sessionFallsBackToHighest() {
        let ultra = UsageSnapshot.snapshot(session: nil, weekly: 0.46, fable: 0.15)

        let content = MenuBarContent(snapshot: ultra, metric: .session, now: now)

        #expect(content.text == "46%")
        #expect(content.accessibilityLabel == "Menu Bar Usage for Claude, Weekly Limit 46%")
    }

    @Test("the picker offers only the quotas the account has")
    func pickerOptions() {
        let ultra = UsageSnapshot.snapshot(session: nil, fable: 0.15)
        let maxPlan = UsageSnapshot.snapshot(session: 0.1, fable: 0.15)
        let pro = UsageSnapshot.snapshot(session: 0.1)

        #expect(MenuBarMetric.options(for: ultra) == [.off, .highest, .weekly, .scopedWeekly])
        #expect(MenuBarMetric.options(for: maxPlan) == [.off, .highest, .session, .weekly, .scopedWeekly])
        #expect(MenuBarMetric.options(for: pro) == [.off, .highest, .session, .weekly])
        // Before data arrives the plan isn't known yet.
        #expect(MenuBarMetric.options(for: nil) == [.off, .highest, .session, .weekly, .scopedWeekly])
    }

    @Test("a choice the account can't show resolves to the highest quota; the rest stand")
    func resolvedChoice() {
        let ultra = UsageSnapshot.snapshot(session: nil, fable: 0.15)
        let pro = UsageSnapshot.snapshot(session: 0.1)

        #expect(MenuBarMetric.session.resolved(for: ultra) == .highest)
        #expect(MenuBarMetric.scopedWeekly.resolved(for: pro) == .highest)
        #expect(MenuBarMetric.session.resolved(for: pro) == .session)
        #expect(MenuBarMetric.scopedWeekly.resolved(for: ultra) == .scopedWeekly)
        #expect(MenuBarMetric.weekly.resolved(for: ultra) == .weekly)
        #expect(MenuBarMetric.session.resolved(for: nil) == .session)
    }

    @Test("the model option is named after the account's model limit")
    func modelOptionTitle() {
        #expect(MenuBarMetric.scopedWeekly.title(for: .snapshot(fable: 0.15)) == "Fable weekly limit")
        #expect(MenuBarMetric.scopedWeekly.title(for: nil) == "Model weekly limit")
    }

    @Test("the warning marks a quota at 90–99% that isn't the one shown")
    func warningRule() {
        let nearLimit = UsageSnapshot.snapshot(session: 0.55, weekly: 0.95)

        let off = MenuBarContent(snapshot: nearLimit, metric: .off, now: now)
        #expect(off.text == nil)
        #expect(off.showsWarning == true)

        let session = MenuBarContent(snapshot: nearLimit, metric: .session, now: now)
        #expect(session.text == "55%")
        #expect(session.showsWarning == true)

        let highest = MenuBarContent(snapshot: nearLimit, metric: .highest, now: now)
        #expect(highest.text == "95%")
        #expect(highest.showsWarning == false)

        // At 100% the full gauge is the signal; no reset time means no countdown either.
        let full = MenuBarContent(snapshot: .snapshot(session: 0.55, weekly: 1.0, weeklyResetsAt: nil), metric: .off, now: now)
        #expect(full.text == nil)
        #expect(full.showsWarning == false)
    }

    @Test("a used-up quota counts down to its reset, whatever the metric")
    func countdownReplacesTheNumber() {
        let lockedOut = UsageSnapshot.snapshot(session: 1.0, sessionResetsAt: now.addingTimeInterval(72 * 60), weekly: 0.95)

        for metric in MenuBarMetric.allCases {
            let content = MenuBarContent(snapshot: lockedOut, metric: metric, now: now)
            #expect(content.text == "↻ 1:12", "\(metric)")
            #expect(content.showsWarning == false, "\(metric)")
        }
    }

    private nonisolated static let countdowns: [(TimeInterval, String)] = [
        (30, "↻ 0:01"), (2_700, "↻ 0:45"), (4_320, "↻ 1:12"), (86_340, "↻ 23:59"),
        (172_800, "↻ 2d"), (183_600, "↻ 2d 3h"),
    ]

    @Test("the countdown is h:mm under a day and days and hours beyond", arguments: countdowns)
    func countdownFormat(seconds: TimeInterval, text: String) {
        let snapshot = UsageSnapshot.snapshot(weekly: 1.0, weeklyResetsAt: now.addingTimeInterval(seconds))

        #expect(MenuBarContent(snapshot: snapshot, metric: .off, now: now).text == text)
    }

    @Test("with several quotas used up, the soonest reset counts down")
    func soonestFullBarWins() {
        let snapshot = UsageSnapshot.snapshot(
            session: 1.0, sessionResetsAt: now.addingTimeInterval(2 * 86_400),
            weekly: 1.0, weeklyResetsAt: now.addingTimeInterval(3600)
        )

        #expect(MenuBarContent(snapshot: snapshot, metric: .highest, now: now).text == "↻ 1:00")
    }

    @Test("the gauge follows the highest quota", arguments: [
        (0.2, "gauge.with.dots.needle.0percent"), (0.4, "gauge.with.dots.needle.33percent"),
        (0.7, "gauge.with.dots.needle.67percent"), (0.95, "gauge.with.dots.needle.100percent"),
    ])
    func gaugeFollowsPeak(peak: Double, symbol: String) {
        let snapshot = UsageSnapshot.snapshot(session: 0.1, weekly: peak)

        #expect(MenuBarContent(snapshot: snapshot, metric: .off, now: now).symbolName == symbol)
    }

    @Test("the accessibility label says what is shown")
    func accessibility() {
        let shown = MenuBarContent(snapshot: .snapshot(session: 0.55), metric: .session, now: now)
        #expect(shown.accessibilityLabel == "Menu Bar Usage for Claude, Current Session 55%")

        let warned = MenuBarContent(snapshot: .snapshot(session: 0.55, weekly: 0.95), metric: .off, now: now)
        #expect(warned.accessibilityLabel == "Menu Bar Usage for Claude, Weekly Limit above 90%")

        let shownAndWarned = MenuBarContent(snapshot: .snapshot(session: 0.55, weekly: 0.95), metric: .session, now: now)
        #expect(shownAndWarned.accessibilityLabel == "Menu Bar Usage for Claude, Current Session 55%, Weekly Limit above 90%")

        let locked = MenuBarContent(snapshot: .snapshot(session: 1.0, sessionResetsAt: now.addingTimeInterval(72 * 60)), metric: .off, now: now)
        #expect(locked.accessibilityLabel == "Menu Bar Usage for Claude, Current Session used up, resets in 1 hour 12 minutes")
    }

    @Test("VoiceOver hears the countdown in words", arguments: [
        (30.0, "1 minute"), (2_700.0, "45 minutes"), (4_320.0, "1 hour 12 minutes"), (7_200.0, "2 hours"),
        (172_800.0, "2 days"), (183_600.0, "2 days 3 hours"),
    ])
    func spokenCountdown(seconds: TimeInterval, words: String) {
        #expect(MenuBarContent.spokenCountdown(until: now.addingTimeInterval(seconds), from: now) == words)
    }
}
