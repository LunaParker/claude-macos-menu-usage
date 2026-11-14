//
//  ResetAlertsTests.swift
//  ClaudeUsageTests
//
//  The three limit reset notifications: a watched quota at 100% that a reset
//  could clear, a reset about to expire, and a new reset. Each fires once.
//

import Foundation
import Testing
@testable import ClaudeUsage

@Suite("ResetAlerts")
struct ResetAlertsTests {
    typealias F = ResetFixtures

    private let all = ResetAlerts.Preferences(atLimit: true, expiring: true, newReset: true, watched: [.session, .weekly, .scopedWeekly])

    private func evaluate(
        _ alerts: inout ResetAlerts,
        _ resets: LimitResets = F.all,
        _ snapshot: UsageSnapshot = F.snapshot(weekly: 0.4, fable: 0.1),
        preferences: ResetAlerts.Preferences? = nil,
        canDeliver: Bool = true,
        now: Date = F.now
    ) -> [ResetAlerts.Alert] {
        alerts.evaluate(resets: resets, snapshot: snapshot, preferences: preferences ?? all, canDeliver: canDeliver, now: now)
    }

    private func message(_ alert: ResetAlerts.Alert, now: Date = F.now) -> UsageAlerts.Message {
        alert.message(scopedTitle: "Fable", now: now, locale: F.locale, timeZone: F.timeZone)
    }

    // MARK: New reset

    @Test("the first check only records the resets already held")
    func firstCheckSeeds() {
        var alerts = ResetAlerts()
        #expect(evaluate(&alerts).isEmpty)
        #expect(evaluate(&alerts).isEmpty)
    }

    @Test("a reset that wasn't there before is announced once")
    func newResetOnce() throws {
        var alerts = ResetAlerts()
        _ = evaluate(&alerts, LimitResets(grants: [F.weekly]))

        let due = evaluate(&alerts, F.all)
        #expect(due.count == 1)
        let alert = try #require(due.first)
        #expect(message(alert) == UsageAlerts.Message(
            title: "New Limit Reset",
            body: "You have 2 new Fable resets. They expire March 9, 2027.",
            identifier: "limit-reset-new-scopedWeekly"
        ))
        #expect(evaluate(&alerts, F.all).isEmpty)
    }

    @Test("with new-reset alerts off, a new reset is recorded and never announced later")
    func newResetSwitchedOff() {
        var alerts = ResetAlerts()
        _ = evaluate(&alerts, LimitResets(grants: [F.weekly]))
        var off = all
        off.newReset = false

        #expect(evaluate(&alerts, F.all, preferences: off).isEmpty)
        #expect(evaluate(&alerts, F.all).isEmpty)
    }

    @Test("one new reset reads in the singular")
    func newResetSingular() throws {
        var alerts = ResetAlerts()
        _ = evaluate(&alerts, LimitResets(grants: []))
        let alert = try #require(evaluate(&alerts, LimitResets(grants: [F.fableA])).first)
        #expect(message(alert).body == "You have a new Fable reset. It expires March 9, 2027.")
    }

    // MARK: At a limit

    @Test("a watched quota at 100% that a reset clears is announced once per window")
    func atLimitOncePerWindow() throws {
        var alerts = ResetAlerts()
        _ = evaluate(&alerts)
        // Monday Nov 16, 10:00 PM in Toronto.
        let resetsAt = Date(timeIntervalSince1970: 1_794_884_400)
        let full = F.snapshot(weekly: 1, fable: 0.38, resetsAt: resetsAt)

        let due = evaluate(&alerts, F.all, full)
        let alert = try #require(due.first)
        #expect(due.count == 1)
        #expect(message(alert) == UsageAlerts.Message(
            title: "Limit Reset Available",
            body: "Your weekly limit is at 100% and resets Monday at 10:00\u{202F}PM. A weekly reset can clear it now on claude.ai.",
            identifier: "limit-reset-at-limit-weekly"
        ))
        // The API jitters the reset time by fractions of a second.
        #expect(evaluate(&alerts, F.all, F.snapshot(weekly: 1, fable: 0.38, resetsAt: resetsAt.addingTimeInterval(0.6))).isEmpty)

        let nextWindow = F.snapshot(weekly: 1, fable: 0.38, resetsAt: resetsAt.addingTimeInterval(7 * 86_400))
        #expect(evaluate(&alerts, F.all, nextWindow).count == 1)
    }

    @Test("a full Fable bar suggests a Fable reset")
    func atLimitFable() throws {
        var alerts = ResetAlerts()
        _ = evaluate(&alerts)
        let alert = try #require(evaluate(&alerts, F.all, F.snapshot(weekly: 0.6, fable: 1)).first)
        #expect(message(alert).body.hasSuffix("A Fable reset can clear it now on claude.ai."))
        #expect(message(alert).body.hasPrefix("Your Fable limit is at 100% and resets "))
    }

    @Test("an unwatched quota, or alerts switched off, say nothing")
    func atLimitNeedsWatchedAndOn() {
        var alerts = ResetAlerts()
        _ = evaluate(&alerts)
        let full = F.snapshot(weekly: 1, fable: 0.38)
        var unwatched = all
        unwatched.watched = [.scopedWeekly]
        var off = all
        off.atLimit = false

        #expect(evaluate(&alerts, F.all, full, preferences: unwatched).isEmpty)
        #expect(evaluate(&alerts, F.all, full, preferences: off).isEmpty)
        // Neither consumed it, so it fires once both allow it.
        #expect(evaluate(&alerts, F.all, full).count == 1)
    }

    @Test("an at-limit alert waits while notifications can't be delivered")
    func atLimitWaitsForPermission() {
        var alerts = ResetAlerts()
        _ = evaluate(&alerts)
        let full = F.snapshot(weekly: 1, fable: 0.38)

        #expect(evaluate(&alerts, F.all, full, canDeliver: false).isEmpty)
        #expect(evaluate(&alerts, F.all, full).count == 1)
    }

    @Test("no reset clears the full bar, no alert")
    func atLimitWithoutReset() {
        var alerts = ResetAlerts()
        _ = evaluate(&alerts, LimitResets(grants: [F.fableA]))
        #expect(evaluate(&alerts, LimitResets(grants: [F.fableA]), F.snapshot(weekly: 1, fable: 0.2)).isEmpty)
    }

    // MARK: Expiring

    @Test("a reset is announced once when it's three days from expiring")
    func expiringOnce() throws {
        var alerts = ResetAlerts()
        _ = evaluate(&alerts)
        // Dec 7, 2026 6:00 PM in Toronto: 2 days 23 hours before the weekly reset expires.
        let soon = Date(timeIntervalSince1970: 1_796_684_400)
        #expect(evaluate(&alerts, now: soon.addingTimeInterval(-2 * 3600)).isEmpty)

        let due = evaluate(&alerts, now: soon)
        let alert = try #require(due.first)
        #expect(due.count == 1)
        #expect(message(alert, now: soon) == UsageAlerts.Message(
            title: "Limit Reset Expiring",
            body: "Your weekly reset expires Thursday at 5:00\u{202F}PM. Use it on claude.ai before then.",
            identifier: "limit-reset-expiring-weekly+scopedWeekly"
        ))
        #expect(evaluate(&alerts, now: soon.addingTimeInterval(3600)).isEmpty)
    }

    @Test("resets expiring together are announced together, in the plural")
    func expiringPlural() throws {
        var alerts = ResetAlerts()
        _ = evaluate(&alerts)
        let soon = F.fableExpiry.addingTimeInterval(-86_400)
        let alert = try #require(evaluate(&alerts, now: soon).first)
        #expect(message(alert, now: soon).body == "Your 2 Fable resets expire tomorrow at 2:59\u{202F}AM. Use them on claude.ai before then.")
    }

    // MARK: Wording and persistence

    @Test("a model name starting with a vowel takes an")
    func article() throws {
        var alerts = ResetAlerts()
        _ = evaluate(&alerts)
        let alert = try #require(evaluate(&alerts, F.all, F.snapshot(weekly: 0.6, fable: 1)).first)
        let body = alert.message(scopedTitle: "Opus", now: F.now, locale: F.locale, timeZone: F.timeZone).body
        #expect(body.hasSuffix("An Opus reset can clear it now on claude.ai."))
    }

    @Test("survives a relaunch")
    func roundTrip() {
        let defaults = TestDefaults.make()
        var alerts = ResetAlerts()
        _ = evaluate(&alerts)
        _ = evaluate(&alerts, F.all, F.snapshot(weekly: 1, fable: 0.38))
        alerts.save(to: defaults)

        var reloaded = ResetAlerts.load(from: defaults)
        #expect(reloaded == alerts)
        #expect(evaluate(&reloaded, F.all, F.snapshot(weekly: 1, fable: 0.38)).isEmpty)
    }

    @Test("preferences read the Notifications tab's switches, with their defaults")
    func preferencesFromDefaults() {
        let defaults = TestDefaults.make()
        let initial = ResetAlerts.Preferences(defaults: defaults)
        #expect(initial == ResetAlerts.Preferences(atLimit: true, expiring: true, newReset: false, watched: [.session, .weekly, .scopedWeekly]))

        defaults.set(false, forKey: SettingsKeys.notifyResetAtLimit.name)
        defaults.set(true, forKey: SettingsKeys.notifyNewReset.name)
        defaults.set(false, forKey: SettingsKeys.notifyForWeekly.name)
        #expect(ResetAlerts.Preferences(defaults: defaults) == ResetAlerts.Preferences(atLimit: false, expiring: true, newReset: true, watched: [.session, .scopedWeekly]))
    }
}
