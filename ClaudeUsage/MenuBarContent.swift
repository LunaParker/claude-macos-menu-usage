//
//  MenuBarContent.swift
//  Menu Bar Usage for Claude
//
//  What the menu bar shows beside the gauge: the chosen quota's percentage,
//  a warning for a quota near its limit that isn't the one shown, or, while
//  any quota is used up, the time until it resets. Pure, so the label view
//  only draws it.
//

import Foundation

/// Which quota's percentage sits beside the gauge.
nonisolated enum MenuBarMetric: String, CaseIterable, Sendable {
    case off
    case highest
    case session
    case weekly
    case scopedWeekly
}

nonisolated struct MenuBarContent: Equatable, Sendable {
    let symbolName: String
    /// The percentage or reset countdown; nil for the icon alone.
    let text: String?
    let showsWarning: Bool
    let accessibilityLabel: String

    private static let appName = "Menu Bar Usage for Claude"

    init(snapshot: UsageSnapshot?, metric: MenuBarMetric, now: Date) {
        guard let snapshot else {
            symbolName = "gauge.with.dots.needle.bottom.50percent"
            text = nil
            showsWarning = false
            accessibilityLabel = Self.appName
            return
        }
        symbolName = Self.symbol(forPeak: snapshot.peakUtilization)

        // The soonest reset among used-up quotas is the next moment anything changes.
        let full = snapshot.bars
            .filter { $0.fraction >= 1 && ($0.resetsAt.map { $0 > now } ?? false) }
            .min { $0.resetsAt! < $1.resetsAt! }
        let nearLimit = { (bar: UsageSnapshot.Bar) in bar.fraction >= 0.9 && bar.fraction < 1 }

        if let full, let resetsAt = full.resetsAt {
            text = "↻ \(Self.countdown(until: resetsAt, from: now))"
            showsWarning = false
            accessibilityLabel = "\(Self.appName), \(full.title) used up, resets in \(Self.spokenCountdown(until: resetsAt, from: now))"
        } else if let shown = Self.bar(for: metric, in: snapshot) {
            text = shown.percentLabel
            let warned = snapshot.bars.first { $0.id != shown.id && nearLimit($0) }
            showsWarning = warned != nil
            accessibilityLabel = "\(Self.appName), \(shown.title) \(shown.percentLabel)"
                + (warned.map { ", \($0.title) above 90%" } ?? "")
        } else {
            text = nil
            let warned = snapshot.bars.first(where: nearLimit)
            showsWarning = warned != nil
            accessibilityLabel = warned.map { "\(Self.appName), \($0.title) above 90%" } ?? Self.appName
        }
    }

    private static func bar(for metric: MenuBarMetric, in snapshot: UsageSnapshot) -> UsageSnapshot.Bar? {
        switch metric {
        case .off: nil
        case .session: snapshot.session
        case .weekly: snapshot.weekly
        case .scopedWeekly: snapshot.scopedWeekly ?? highest(in: snapshot)
        case .highest: highest(in: snapshot)
        }
    }

    private static func highest(in snapshot: UsageSnapshot) -> UsageSnapshot.Bar? {
        snapshot.bars.max { $0.fraction < $1.fraction }
    }

    private static func symbol(forPeak peak: Double) -> String {
        if peak >= 0.9 { return "gauge.with.dots.needle.100percent" }
        if peak >= 0.66 { return "gauge.with.dots.needle.67percent" }
        if peak >= 0.33 { return "gauge.with.dots.needle.33percent" }
        return "gauge.with.dots.needle.0percent"
    }

    /// "1:12" under a day, rounded up so it never reads 0:00 while still locked; "2d 3h" beyond.
    static func countdown(until resetsAt: Date, from now: Date) -> String {
        let seconds = max(0, resetsAt.timeIntervalSince(now))
        if seconds >= 86_400 {
            let days = Int(seconds / 86_400)
            let hours = Int(seconds.truncatingRemainder(dividingBy: 86_400) / 3600)
            return hours == 0 ? "\(days)d" : "\(days)d \(hours)h"
        }
        let minutes = Int((seconds / 60).rounded(.up))
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    /// The same countdown in words, for VoiceOver: "1 hour 12 minutes", "2 days 3 hours".
    static func spokenCountdown(until resetsAt: Date, from now: Date) -> String {
        let seconds = max(0, resetsAt.timeIntervalSince(now))
        let units: [(Int, String)]
        if seconds >= 86_400 {
            units = [(Int(seconds / 86_400), "day"), (Int(seconds.truncatingRemainder(dividingBy: 86_400) / 3600), "hour")]
        } else {
            let minutes = Int((seconds / 60).rounded(.up))
            units = [(minutes / 60, "hour"), (minutes % 60, "minute")]
        }
        let words = units.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
        return words.isEmpty ? "less than a minute" : words.joined(separator: " ")
    }
}
