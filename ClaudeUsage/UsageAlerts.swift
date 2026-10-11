//
//  UsageAlerts.swift
//  Menu Bar Usage for Claude
//
//  One ThresholdTracker per quota, and the words each alert is delivered
//  with. NotificationManager owns an instance and saves it after each change.
//

import Foundation

nonisolated struct UsageAlerts: Equatable, Sendable {
    /// What the Notifications tab has switched on.
    struct Preferences: Equatable, Sendable {
        var thresholds: Set<Int>
        var resetAlert: Bool
        var watched: Set<UsageSnapshot.Bar.Kind>

        init(thresholds: Set<Int>, resetAlert: Bool, watched: Set<UsageSnapshot.Bar.Kind>) {
            self.thresholds = thresholds
            self.resetAlert = resetAlert
            self.watched = watched
        }

        init(defaults: UserDefaults) {
            thresholds = Set(Self.thresholdKeys.filter { defaults[$0.value] }.keys)
            resetAlert = defaults[SettingsKeys.notifyOnReset]
            watched = Set(Self.quotaKeys.filter { defaults[$0.value] }.keys)
        }

        private static let thresholdKeys = [
            50: SettingsKeys.notifyAt50Percent,
            75: SettingsKeys.notifyAt75Percent,
            90: SettingsKeys.notifyAt90Percent,
        ]

        static let quotaKeys: [UsageSnapshot.Bar.Kind: SettingKey<Bool>] = [
            .session: SettingsKeys.notifyForSession,
            .weekly: SettingsKeys.notifyForWeekly,
            .scopedWeekly: SettingsKeys.notifyForScopedWeekly,
        ]
    }

    struct Alert: Equatable, Sendable {
        let bar: UsageSnapshot.Bar
        let event: ThresholdTracker.Event
    }

    private var trackers: [UsageSnapshot.Bar.Kind: ThresholdTracker] = [:]

    init() {}

    /// Advances every quota the snapshot carries and returns the alerts now due.
    /// An unwatched quota is evaluated with nothing enabled, so its crossings
    /// stay pending until the user switches it on.
    mutating func evaluate(snapshot: UsageSnapshot, preferences: Preferences, canDeliver: Bool) -> [Alert] {
        var alerts: [Alert] = []
        for bar in snapshot.bars {
            let watched = preferences.watched.contains(bar.id)
            var tracker = trackers[bar.id] ?? ThresholdTracker()
            let events = tracker.evaluate(
                fraction: bar.fraction,
                resetsAt: bar.resetsAt,
                enabled: watched ? preferences.thresholds : [],
                resetAlertEnabled: watched && preferences.resetAlert,
                canDeliver: canDeliver
            )
            trackers[bar.id] = tracker
            alerts += events.map { Alert(bar: bar, event: $0) }
        }
        return alerts
    }
}

// MARK: - Persistence

nonisolated extension UsageAlerts {
    static func storageKey(for kind: UsageSnapshot.Bar.Kind) -> String {
        "alertTracker.\(kind.rawValue)"
    }

    static func load(from defaults: UserDefaults) -> UsageAlerts {
        var alerts = UsageAlerts()
        for kind in UsageSnapshot.Bar.Kind.allCases {
            if let data = defaults.data(forKey: storageKey(for: kind)),
               let tracker = try? JSONDecoder().decode(ThresholdTracker.self, from: data) {
                alerts.trackers[kind] = tracker
            }
        }
        return alerts
    }

    func save(to defaults: UserDefaults) {
        for (kind, tracker) in trackers {
            if let data = try? JSONEncoder().encode(tracker) {
                defaults.set(data, forKey: Self.storageKey(for: kind))
            }
        }
    }
}

// MARK: - Wording

nonisolated extension UsageAlerts {
    struct Message: Equatable, Sendable {
        let title: String
        let body: String
        let identifier: String
    }
}

nonisolated extension UsageAlerts.Alert {
    func message(
        now: Date,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> UsageAlerts.Message {
        switch event {
        case .crossed(let percent):
            var body = "Your \(quotaName) usage has reached \(percent)%."
            if let resets = resetSentence(now: now, locale: locale, timeZone: timeZone) {
                body += " " + resets
            }
            return UsageAlerts.Message(
                title: "Claude Usage Alert",
                body: body,
                identifier: "usage-threshold-\(bar.id.rawValue)-\(percent)"
            )
        case .windowReset:
            return UsageAlerts.Message(
                title: "Claude Usage Reset",
                body: "Your \(limitName) has reset. You're good to go!",
                identifier: "usage-reset-\(bar.id.rawValue)"
            )
        }
    }

    private var quotaName: String {
        switch bar.id {
        case .session: "current session"
        case .weekly: "weekly"
        case .scopedWeekly: "\(bar.title) weekly"
        }
    }

    private var limitName: String {
        switch bar.id {
        case .session: "session usage limit"
        case .weekly: "weekly usage limit"
        case .scopedWeekly: "\(bar.title) weekly limit"
        }
    }

    private func resetSentence(now: Date, locale: Locale, timeZone: TimeZone) -> String? {
        bar.resetsAt
            .flatMap { ResetWording.phrase(for: $0, now: now, locale: locale, timeZone: timeZone) }
            .map { "Resets \($0)." }
    }
}

/// "at 6:00 AM" today, "tomorrow at 2:00 AM", "Thursday at 3:00 PM" beyond:
/// decided by calendar day, so a reset 23 hours away isn't given as a bare
/// time that reads as already past. Nil once the reset has passed.
nonisolated enum ResetWording {
    static func phrase(for resetsAt: Date, now: Date, locale: Locale, timeZone: TimeZone) -> String? {
        guard resetsAt > now else { return nil }
        let style = Date.FormatStyle(locale: locale, timeZone: timeZone)
        let time = resetsAt.formatted(style.hour().minute())
        switch daysAhead(of: resetsAt, from: now, timeZone: timeZone) {
        case 0: return "at \(time)"
        case 1: return "tomorrow at \(time)"
        default: return "\(resetsAt.formatted(style.weekday(.wide))) at \(time)"
        }
    }

    /// Calendar days between `now` and `date` in `timeZone`: 0 today, 1 tomorrow.
    static func daysAhead(of date: Date, from now: Date, timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    }
}
