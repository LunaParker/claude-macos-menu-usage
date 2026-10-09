//
//  ThresholdTracker.swift
//  Menu Bar Usage for Claude
//
//  Decides which session-usage alerts are due. NotificationManager delivers
//  them and saves the tracker after each change, so a relaunch in the same
//  window doesn't repeat an alert.
//

import Foundation

nonisolated struct ThresholdTracker: Codable, Equatable, Sendable {
    enum Event: Equatable, Sendable {
        case crossed(percent: Int)
        case windowReset
    }

    static let percents = [50, 75, 90]

    private(set) var windowResetsAt: Date?
    private(set) var fired: Set<Int> = []
    private(set) var sawCapacity = false

    /// Advances the tracker with a new reading and returns the alerts now due.
    /// Without `canDeliver`, crossings stay pending so a later reading can fire them.
    mutating func evaluate(
        fraction: Double,
        resetsAt: Date?,
        enabled: Set<Int>,
        resetAlertEnabled: Bool,
        canDeliver: Bool
    ) -> [Event] {
        var events: [Event] = []

        if !Self.isSameResetTime(resetsAt, windowResetsAt) {
            if windowResetsAt != nil, sawCapacity, resetAlertEnabled, canDeliver {
                events.append(.windowReset)
            }
            // Only the highest threshold already passed may fire, so a launch
            // or a new window never bursts stale alerts.
            fired = Set(Self.percents.filter { fraction >= Double($0) / 100 }.dropLast())
            sawCapacity = false
            windowResetsAt = resetsAt
        }

        if fraction >= 1 {
            sawCapacity = true
        }

        guard canDeliver else { return events }
        for percent in Self.percents
        where fraction >= Double(percent) / 100 && enabled.contains(percent) && !fired.contains(percent) {
            fired.insert(percent)
            events.append(.crossed(percent: percent))
        }
        return events
    }

    /// The endpoint jitters `resets_at` by fractions of a second within one
    /// window, and windows are hours apart, so two seconds of tolerance is safe.
    static func isSameResetTime(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case (let a?, let b?): return abs(a.timeIntervalSince1970 - b.timeIntervalSince1970) < 2
        }
    }
}

extension ThresholdTracker {
    private static let storageKey = "sessionAlertTracker"

    static func load(from defaults: UserDefaults) -> ThresholdTracker? {
        defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(ThresholdTracker.self, from: $0) }
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
