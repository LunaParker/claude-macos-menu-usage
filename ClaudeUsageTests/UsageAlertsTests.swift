//
//  UsageAlertsTests.swift
//  ClaudeUsageTests
//
//  UsageAlerts runs one ThresholdTracker per quota: the session, the weekly
//  limit and the model-scoped weekly limit each cross their thresholds and
//  rotate their windows on their own, a quota the user isn't watching keeps
//  its crossings pending, and the per-quota state survives a relaunch.
//

import Foundation
import Testing
@testable import ClaudeUsage

@Suite("UsageAlerts")
struct UsageAlertsTests {

    private let all = UsageAlerts.Preferences(
        thresholds: [50, 75, 90],
        resetAlert: true,
        watched: [.session, .weekly, .scopedWeekly]
    )

    @Test("each quota crosses its thresholds on its own")
    func quotasAreIndependent() {
        var alerts = UsageAlerts()
        _ = evaluate(&alerts, .snapshot(session: 0.1, weekly: 0.1))

        let session = evaluate(&alerts, .snapshot(session: 0.55, weekly: 0.1))
        #expect(session.map(\.bar.id) == [.session])
        #expect(session.map(\.event) == [.crossed(percent: 50)])

        let weekly = evaluate(&alerts, .snapshot(session: 0.55, weekly: 0.92))
        #expect(weekly.map(\.bar.id) == [.weekly])
        #expect(weekly.map(\.event) == [.crossed(percent: 90)])
    }

    @Test("the model-scoped quota alerts under the name the API gives it")
    func scopedQuotaCarriesItsBar() {
        var alerts = UsageAlerts()
        _ = evaluate(&alerts, .snapshot(fable: 0.1))

        let due = evaluate(&alerts, .snapshot(fable: 0.80))

        #expect(due == [UsageAlerts.Alert(
            bar: TestSnapshots.bar(.scopedWeekly, "Fable", 0.80, TestSnapshots.weeklyWindow),
            event: .crossed(percent: 75)
        )])
    }

    @Test("a quota that isn't watched keeps its crossings pending")
    func unwatchedQuotaStaysPending() {
        var alerts = UsageAlerts()
        var sessionOnly = all
        sessionOnly.watched = [.session]
        _ = evaluate(&alerts, .snapshot(weekly: 0.1), sessionOnly)

        #expect(evaluate(&alerts, .snapshot(weekly: 0.92), sessionOnly).isEmpty)
        #expect(evaluate(&alerts, .snapshot(weekly: 0.92), all).map(\.event) == [.crossed(percent: 90)])
    }

    @Test("a snapshot without the model-scoped bar leaves that tracker alone")
    func missingScopedBarIsSkipped() {
        var alerts = UsageAlerts()
        _ = evaluate(&alerts, .snapshot(fable: 0.1))
        #expect(evaluate(&alerts, .snapshot(fable: 0.55)).map(\.event) == [.crossed(percent: 50)])

        let before = alerts
        #expect(evaluate(&alerts, .snapshot(fable: nil)).isEmpty)
        #expect(alerts == before)

        // The bar is back in the same window: 50% doesn't fire again.
        #expect(evaluate(&alerts, .snapshot(fable: 0.56)).isEmpty)
    }

    @Test("a new session window re-arms the session, not the weekly limit")
    func windowsRotateIndependently() {
        var alerts = UsageAlerts()
        _ = evaluate(&alerts, .snapshot(session: 0.1, weekly: 0.1))
        #expect(evaluate(&alerts, .snapshot(session: 0.55, weekly: 0.55)).count == 2)

        let nextSession = TestSnapshots.sessionWindow.addingTimeInterval(5 * 3600)
        #expect(evaluate(&alerts, .snapshot(session: 0.1, sessionResetsAt: nextSession, weekly: 0.56)).isEmpty)

        let due = evaluate(&alerts, .snapshot(session: 0.55, sessionResetsAt: nextSession, weekly: 0.56))
        #expect(due.map(\.bar.id) == [.session])
    }

    @Test("a reset alert names the quota that reset")
    func resetNamesItsQuota() {
        var alerts = UsageAlerts()
        _ = evaluate(&alerts, .snapshot(weekly: 1.0))

        let nextWeek = TestSnapshots.weeklyWindow.addingTimeInterval(7 * 86_400)
        let due = evaluate(&alerts, .snapshot(weekly: 0.0, weeklyResetsAt: nextWeek))

        #expect(due.map(\.bar.id) == [.weekly])
        #expect(due.map(\.event) == [.windowReset])
    }

    @Test("saved state survives a relaunch, so no quota repeats an alert")
    func persistsPerQuota() {
        let defaults = TestDefaults.make()
        var first = UsageAlerts()
        #expect(evaluate(&first, .snapshot(session: 0.80, weekly: 0.55)).count == 2)
        first.save(to: defaults)

        var relaunched = UsageAlerts.load(from: defaults)

        #expect(relaunched == first)
        #expect(evaluate(&relaunched, .snapshot(session: 0.80, weekly: 0.55)).isEmpty)
    }

    @Test("an older build's session tracker is migrated, so its alerts aren't repeated")
    func migratesSessionTracker() throws {
        let defaults = TestDefaults.make()
        var tracker = ThresholdTracker()
        _ = tracker.evaluate(
            fraction: 0.80,
            resetsAt: TestSnapshots.sessionWindow,
            enabled: [50, 75, 90],
            resetAlertEnabled: true,
            canDeliver: true
        )
        defaults.set(try JSONEncoder().encode(tracker), forKey: "sessionAlertTracker")

        PreferenceMigrations.run(on: defaults)
        var alerts = UsageAlerts.load(from: defaults)

        #expect(evaluate(&alerts, .snapshot(session: 0.80)).isEmpty)
        #expect(defaults.object(forKey: "sessionAlertTracker") == nil)
    }

    @Test("preferences come from the settings keys; every quota is watched by default")
    func preferencesFromDefaults() {
        let defaults = TestDefaults.make()
        #expect(UsageAlerts.Preferences(defaults: defaults) == UsageAlerts.Preferences(
            thresholds: [],
            resetAlert: false,
            watched: [.session, .weekly, .scopedWeekly]
        ))

        defaults.set(true, forKey: SettingsKeys.notifyAt90Percent.name)
        defaults.set(true, forKey: SettingsKeys.notifyOnReset.name)
        defaults.set(false, forKey: SettingsKeys.notifyForWeekly.name)

        #expect(UsageAlerts.Preferences(defaults: defaults) == UsageAlerts.Preferences(
            thresholds: [90],
            resetAlert: true,
            watched: [.session, .scopedWeekly]
        ))
    }

    private func evaluate(
        _ alerts: inout UsageAlerts,
        _ snapshot: UsageSnapshot,
        _ preferences: UsageAlerts.Preferences? = nil
    ) -> [UsageAlerts.Alert] {
        alerts.evaluate(snapshot: snapshot, preferences: preferences ?? all, canDeliver: true)
    }
}

@Suite("Alert text")
struct AlertTextTests {

    private let locale = Locale(identifier: "en_US")
    private let timeZone = TimeZone(identifier: "America/Toronto")!

    @Test("a session crossing gives the percentage and the time it resets")
    func sessionCrossing() {
        let message = message(.session, "Current Session", 0.75, TestSnapshots.sessionWindow, .crossed(percent: 75))

        #expect(message.title == "Claude Usage Alert")
        #expect(message.body == "Your current session usage has reached 75%. Resets at 6:00\u{202F}AM.")
        #expect(message.identifier == "usage-threshold-session-75")
    }

    @Test("a reset more than a day away is given with its weekday")
    func weeklyCrossing() {
        let message = message(.weekly, "Weekly Limit", 0.90, TestSnapshots.weeklyWindow, .crossed(percent: 90))

        #expect(message.body == "Your weekly usage has reached 90%. Resets Monday at 3:00\u{202F}AM.")
        #expect(message.identifier == "usage-threshold-weekly-90")
    }

    @Test("the model-scoped quota is named after the API's title")
    func scopedCrossing() {
        let message = message(.scopedWeekly, "Fable", 0.90, TestSnapshots.weeklyWindow, .crossed(percent: 90))

        #expect(message.body == "Your Fable weekly usage has reached 90%. Resets Monday at 3:00\u{202F}AM.")
        #expect(message.identifier == "usage-threshold-scopedWeekly-90")
    }

    @Test("a reset tomorrow says so, even within 24 hours")
    func tomorrowCrossing() {
        // Friday 03:00 Toronto; 23 hours later is Saturday 02:00.
        let message = message(.weekly, "Weekly Limit", 0.90, TestSnapshots.now.addingTimeInterval(23 * 3600), .crossed(percent: 90))

        #expect(message.body == "Your weekly usage has reached 90%. Resets tomorrow at 2:00\u{202F}AM.")
    }

    @Test("without a reset time the body stops at the percentage")
    func noResetTime() {
        let message = message(.weekly, "Weekly Limit", 0.90, nil, .crossed(percent: 90))

        #expect(message.body == "Your weekly usage has reached 90%.")
    }

    @Test("a reset alert names the quota that reset", arguments: [
        (UsageSnapshot.Bar.Kind.session, "Current Session", "Your session usage limit has reset. You're good to go!"),
        (.weekly, "Weekly Limit", "Your weekly usage limit has reset. You're good to go!"),
        (.scopedWeekly, "Fable", "Your Fable weekly limit has reset. You're good to go!"),
    ])
    func reset(kind: UsageSnapshot.Bar.Kind, title: String, body: String) {
        let message = message(kind, title, 0.0, TestSnapshots.weeklyWindow, .windowReset)

        #expect(message.title == "Claude Usage Reset")
        #expect(message.body == body)
        #expect(message.identifier == "usage-reset-\(kind.rawValue)")
    }

    private func message(
        _ kind: UsageSnapshot.Bar.Kind,
        _ title: String,
        _ fraction: Double,
        _ resetsAt: Date?,
        _ event: ThresholdTracker.Event
    ) -> UsageAlerts.Message {
        UsageAlerts.Alert(bar: TestSnapshots.bar(kind, title, fraction, resetsAt), event: event)
            .message(now: TestSnapshots.now, locale: locale, timeZone: timeZone)
    }
}
