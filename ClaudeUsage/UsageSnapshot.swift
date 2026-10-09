//
//  UsageSnapshot.swift
//  Menu Bar Usage for Claude
//
//  The display model the popover renders, built from a `UsageResponse`.
//

import Foundation

// MARK: - Display snapshot

/// The data the popover actually renders, derived from a `UsageResponse`.
struct UsageSnapshot: Equatable, Sendable {
    var session: Bar
    var weekly: Bar
    /// The model-scoped weekly quota (currently the Fable limit on Max
    /// 5x/20x plans). Nil when the API reports no such limit — the bar
    /// is presence-gated, so plans without the quota never show it.
    var scopedWeekly: Bar?
    var extraUsage: ExtraUsageSummary?
    var fetchedAt: Date

    /// The highest utilisation across the quota bars (session/weekly/
    /// model-scoped), used to tint the status bar icon. Extra Usage is
    /// deliberately excluded: it represents paid overflow, not remaining
    /// free quota, so mixing it into the "peak" would send the wrong signal.
    var peakUtilization: Double {
        max(session.fraction, weekly.fraction, scopedWeekly?.fraction ?? 0)
    }

    struct Bar: Equatable, Sendable, Identifiable {
        let id: Kind
        let title: String
        /// 0…1 fraction used to fill the progress bar.
        let fraction: Double
        /// Pre-formatted percentage label (e.g. "12%").
        let percentLabel: String
        let resetsAt: Date?

        enum Kind: String, Sendable {
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
        let session = bar(
            kind: .session,
            title: "Current Session",
            window: response.fiveHour
        )
        let weekly = bar(
            kind: .weekly,
            title: "Weekly Limit",
            window: response.sevenDay
        )

        // The model-scoped weekly quota (currently Fable) has no legacy
        // `seven_day_*` field — it exists only as a `weekly_scoped` entry
        // in the `limits` array, and only on plans that have the quota
        // (Max 5x/20x). Presence-gated: no entry, no bar. The title comes
        // from the API so a renamed or re-scoped quota follows along.
        let scopedWeekly: UsageSnapshot.Bar?
        if let entry = response.limits?.first(where: { $0.kind == "weekly_scoped" }),
           let title = entry.scope?.model?.displayName {
            scopedWeekly = bar(
                kind: .scopedWeekly,
                title: title,
                utilization: entry.percent,
                resetsAt: entry.resetsAt
            )
        } else {
            scopedWeekly = nil
        }

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
