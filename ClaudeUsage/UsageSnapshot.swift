//
//  UsageSnapshot.swift
//  Menu Bar Usage for Claude
//
//  The display model the popover renders, built from a `UsageResponse`.
//

import Foundation

// MARK: - Display snapshot

/// The data the popover actually renders, derived from a `UsageResponse`.
nonisolated struct UsageSnapshot: Equatable, Sendable {
    /// The 5-hour session window. Nil when the API reports none: verified
    /// Ultra accounts have no session limit.
    var session: Bar?
    var weekly: Bar
    /// The model-scoped weekly quota (currently the Fable limit on Max 5x
    /// and Ultra plans). Nil when the API reports no such limit — the bar
    /// is presence-gated, so plans without the quota never show it.
    var scopedWeekly: Bar?
    var extraUsage: ExtraUsageSummary?
    var fetchedAt: Date

    /// The highest utilisation across the quota bars (session/weekly/
    /// model-scoped), used to tint the status bar icon. Extra Usage is
    /// deliberately excluded: it represents paid overflow, not remaining
    /// free quota, so mixing it into the "peak" would send the wrong signal.
    var peakUtilization: Double {
        bars.map(\.fraction).max() ?? 0
    }

    /// The quota bars in display order; the session and model-scoped ones only when present.
    var bars: [Bar] {
        [session, weekly, scopedWeekly].compactMap { $0 }
    }

    struct Bar: Equatable, Sendable, Identifiable {
        let id: Kind
        let title: String
        /// 0…1 fraction used to fill the progress bar.
        let fraction: Double
        /// Pre-formatted percentage label (e.g. "12%").
        let percentLabel: String
        let resetsAt: Date?

        enum Kind: String, Sendable, CaseIterable {
            case session
            case weekly
            case scopedWeekly
        }
    }

    /// Everything the Extra Usage card needs to render. Nil when the user
    /// hasn't enabled Extra Usage on their claude.ai account, or when the
    /// API returned an enabled flag but with null numbers.
    struct ExtraUsageSummary: Equatable, Sendable {
        /// 0…1 fraction of the monthly limit consumed.
        let fraction: Double
        /// Pre-formatted percentage label (e.g. "38%").
        let percentLabel: String
        /// Credits consumed this month.
        let used: Double
        /// Credits available this month (the user-set monthly limit).
        let monthlyLimit: Double
        /// Credits remaining, i.e. `monthlyLimit - used`, clamped at zero.
        var remaining: Double { max(0, monthlyLimit - used) }
    }
}

// MARK: - Snapshot builder

extension UsageStore {
    static func buildSnapshot(from response: UsageResponse, fetchedAt: Date = Date()) -> UsageSnapshot {
        // The `limits` array is the newer description of the same quotas; it
        // wins per bar, with the legacy `five_hour`/`seven_day` windows as fallback.
        let limits = response.limits ?? []
        // Verified Ultra accounts have no session. As in Claude Code, a window
        // without a utilization counts as none.
        let session = limits.first { $0.kind == "session" }
            .map { bar(kind: .session, title: "Current Session", utilization: $0.percent, resetsAt: $0.resetsAt) }
            ?? response.fiveHour.flatMap { $0.utilization == nil ? nil : bar(kind: .session, title: "Current Session", window: $0) }
        let weekly = limits.first { $0.kind == "weekly_all" }
            .map { bar(kind: .weekly, title: "Weekly Limit", utilization: $0.percent, resetsAt: $0.resetsAt) }
            ?? bar(kind: .weekly, title: "Weekly Limit", window: response.sevenDay)

        // The model-scoped weekly quota (currently Fable, Max 5x and Ultra) exists only
        // as a `weekly_scoped` entry. Presence-gated: no entry, no bar. The title
        // comes from the API so a renamed quota follows along, and if the API
        // ever lists several, the fullest one is shown.
        let scopedWeekly = limits
            .filter { $0.kind == "weekly_scoped" && $0.scope?.model?.displayName != nil }
            .max { ($0.percent ?? 0) < ($1.percent ?? 0) }
            .map { bar(kind: .scopedWeekly, title: $0.scope!.model!.displayName!, utilization: $0.percent, resetsAt: $0.resetsAt) }

        // The Extra Usage card only appears if the account has actually
        // enabled paid overflow in claude.ai settings — in which case the
        // endpoint returns populated numbers. If anything required is
        // missing we treat it as "not enabled" and hide the card.
        let extraUsage: UsageSnapshot.ExtraUsageSummary?
        if let e = response.extraUsage,
           e.isEnabled,
           let limit = e.monthlyLimit, limit > 0,
           let used = e.usedCredits,
           let util = e.utilization {
            let fraction = min(max(util / 100.0, 0), 1)
            extraUsage = UsageSnapshot.ExtraUsageSummary(
                fraction: fraction,
                percentLabel: Self.percentFormatter.string(from: NSNumber(value: fraction)) ?? "0%",
                used: used,
                monthlyLimit: limit
            )
        } else {
            extraUsage = nil
        }

        return UsageSnapshot(
            session: session,
            weekly: weekly,
            scopedWeekly: scopedWeekly,
            extraUsage: extraUsage,
            fetchedAt: fetchedAt
        )
    }

    private static func bar(
        kind: UsageSnapshot.Bar.Kind,
        title: String,
        window: UsageWindow?
    ) -> UsageSnapshot.Bar {
        bar(kind: kind, title: title, utilization: window?.utilization, resetsAt: window?.resetsAt)
    }

    private static func bar(
        kind: UsageSnapshot.Bar.Kind,
        title: String,
        utilization: Double?,
        resetsAt: Date?
    ) -> UsageSnapshot.Bar {
        let fraction = min(max((utilization ?? 0) / 100.0, 0), 1)
        return UsageSnapshot.Bar(
            id: kind,
            title: title,
            fraction: fraction,
            percentLabel: Self.percentFormatter.string(from: NSNumber(value: fraction)) ?? "0%",
            resetsAt: resetsAt
        )
    }

    private static let percentFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .percent
        f.maximumFractionDigits = 0
        return f
    }()
}
