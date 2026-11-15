//
//  ResetAlerts.swift
//  Menu Bar Usage for Claude
//
//  Decides which limit reset notifications are due and words them.
//  NotificationManager owns an instance and saves it after each change.
//

import Foundation

nonisolated struct ResetAlerts: Codable, Equatable, Sendable {
    /// The Notifications tab's Limit Resets switches, plus Quotas to Watch.
    struct Preferences: Equatable, Sendable {
        var atLimit: Bool
        var expiring: Bool
        var newReset: Bool
        var watched: Set<UsageSnapshot.Bar.Kind>

        init(atLimit: Bool, expiring: Bool, newReset: Bool, watched: Set<UsageSnapshot.Bar.Kind>) {
            self.atLimit = atLimit
            self.expiring = expiring
            self.newReset = newReset
            self.watched = watched
        }

        init(defaults: UserDefaults) {
            atLimit = defaults[SettingsKeys.notifyResetAtLimit]
            expiring = defaults[SettingsKeys.notifyResetExpiring]
            newReset = defaults[SettingsKeys.notifyNewReset]
            watched = Set(UsageAlerts.Preferences.quotaKeys.filter { defaults[$0.value] }.keys)
        }
    }

    enum Alert: Equatable, Sendable {
        /// A watched bar at 100%, and the most targeted reset that clears it.
        case atLimit(UsageSnapshot.Bar, LimitResets.Group)
        case expiring(LimitResets.Group)
        case newReset(LimitResets.Group)
    }

    /// How far ahead of expiry a reset is announced.
    static let expiryNotice: TimeInterval = 3 * 86_400

    /// Grant ids already known, with their expiry; nil until the first check, which only records them.
    private(set) var seenGrants: [String: Date]?
    /// Per bar kind, the window end already announced at its limit.
    private(set) var announcedLimits: [String: Date] = [:]
    /// Grant ids whose expiry was announced, with that expiry.
    private(set) var announcedExpiries: [String: Date] = [:]

    init() {}

    mutating func evaluate(
        resets: LimitResets,
        snapshot: UsageSnapshot,
        preferences: Preferences,
        canDeliver: Bool,
        now: Date
    ) -> [Alert] {
        let current = resets.grants.filter { $0.expiresAt.map { $0 > now } ?? true }
        var alerts: [Alert] = []

        // New resets are recorded even when nobody is told, so switching the alert on later can't flood.
        let held = Dictionary(current.map { ($0.id, $0.expiresAt ?? .distantFuture) }, uniquingKeysWith: { a, _ in a })
        if let seen = seenGrants {
            let fresh = current.filter { seen[$0.id] == nil }
            if preferences.newReset && canDeliver && !fresh.isEmpty {
                alerts += LimitResets.groups(fresh).map(Alert.newReset)
            }
            seenGrants = seen.merging(held) { old, _ in old }.filter { $0.value > now }
        } else {
            seenGrants = held
        }

        // An at-limit or expiry alert that can't go out now stays due, like the usage thresholds.
        let groups = LimitResets.groups(current)
        for bar in snapshot.bars where bar.fraction >= 1 && preferences.watched.contains(bar.id) {
            if let announced = announcedLimits[bar.id.rawValue], ThresholdTracker.isSameResetTime(announced, bar.resetsAt) {
                continue
            }
            guard preferences.atLimit, canDeliver, let group = LimitResets.bestGroup(clearing: bar.id, among: groups) else { continue }
            alerts.append(.atLimit(bar, group))
            announcedLimits[bar.id.rawValue] = bar.resetsAt ?? .distantFuture
        }

        let expiring = current.filter { grant in
            guard let expiry = grant.expiresAt, announcedExpiries[grant.id] == nil else { return false }
            return expiry.timeIntervalSince(now) <= Self.expiryNotice
        }
        if preferences.expiring, canDeliver, !expiring.isEmpty {
            alerts += LimitResets.groups(expiring).map(Alert.expiring)
            for grant in expiring { announcedExpiries[grant.id] = grant.expiresAt }
        }
        announcedExpiries = announcedExpiries.filter { $0.value > now }
        return alerts
    }
}

// MARK: - Persistence

nonisolated extension ResetAlerts {
    static let storageKey = "resetAlerts"

    static func load(from defaults: UserDefaults) -> ResetAlerts {
        guard let data = defaults.data(forKey: storageKey),
              let alerts = try? JSONDecoder().decode(ResetAlerts.self, from: data)
        else { return ResetAlerts() }
        return alerts
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}

// MARK: - Wording

nonisolated extension ResetAlerts.Alert {
    func message(
        scopedTitle: String?,
        now: Date,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> UsageAlerts.Message {
        let words = ResetWords(scopedTitle: scopedTitle, now: now, locale: locale, timeZone: timeZone)
        switch self {
        case .atLimit(let bar, let group):
            var body = "Your \(words.limitPhrase(for: bar.id)) is at 100%"
            if let resets = bar.resetsAt.flatMap({ ResetWording.phrase(for: $0, now: now, locale: locale, timeZone: timeZone) }) {
                body += " and resets \(resets)"
            }
            let noun = words.noun(for: group.clears)
            body += ". \(ResetWords.capitalizedFirst(Self.article(for: noun))) \(noun) can clear it now on claude.ai."
            return UsageAlerts.Message(title: "Limit Reset Available", body: body, identifier: "limit-reset-at-limit-\(bar.id.rawValue)")

        case .expiring(let group):
            let noun = words.noun(for: group.clears, count: group.count)
            let when = group.firstExpiry.flatMap { ResetWording.phrase(for: $0, now: now, locale: locale, timeZone: timeZone) } ?? "soon"
            let body: String
            if group.count == 1 {
                body = "Your \(noun) expires \(when). Use it on claude.ai before then."
            } else if group.sameExpiry {
                body = "Your \(group.count) \(noun) expire \(when). Use them on claude.ai before then."
            } else {
                body = "One of your \(group.count) \(noun) expires \(when). Use it on claude.ai before then."
            }
            return UsageAlerts.Message(title: "Limit Reset Expiring", body: body, identifier: "limit-reset-expiring-\(Self.key(group))")

        case .newReset(let group):
            var body = group.count == 1
                ? "You have \(Self.article(for: "new")) new \(words.noun(for: group.clears))."
                : "You have \(group.count) new \(words.noun(for: group.clears, count: group.count))."
            if let expiry = group.firstExpiry {
                let verb = group.count == 1 ? "It expires" : group.sameExpiry ? "They expire" : "The first expires"
                body += " \(verb) \(words.longDate(expiry))."
            }
            return UsageAlerts.Message(title: "New Limit Reset", body: body, identifier: "limit-reset-new-\(Self.key(group))")
        }
    }

    /// "weekly+scopedWeekly": the limits a group clears, in display order.
    private static func key(_ group: LimitResets.Group) -> String {
        UsageSnapshot.Bar.Kind.allCases.filter(group.clears.contains).map(\.rawValue).joined(separator: "+")
    }

    private static func article(for word: String) -> String {
        guard let first = word.lowercased().first else { return "a" }
        return "aeiou".contains(first) ? "an" : "a"
    }
}
