//
//  ThresholdTracker.swift
//  Menu Bar Usage for Claude
//
//  Decides which alerts are due for one quota's window. UsageAlerts keeps one
//  per quota and NotificationManager saves them after each change, so a
//  relaunch in the same window doesn't repeat an alert.
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
        // One reading, one alert: the highest threshold due supersedes the rest.
        let due = Self.percents.filter { fraction >= Double($0) / 100 && enabled.contains($0) && !fired.contains($0) }
        fired.formUnion(due)
        if let highest = due.last {
            events.append(.crossed(percent: highest))
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
