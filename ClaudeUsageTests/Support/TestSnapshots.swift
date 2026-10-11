//
//  TestSnapshots.swift
//  ClaudeUsageTests
//
//  Display snapshots built directly, so alert tests can set each quota's
//  fraction and window without going through the wire format.
//

import Foundation
@testable import ClaudeUsage

enum TestSnapshots {
    /// 2027-01-15 08:00 UTC, a Friday.
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let sessionWindow = now.addingTimeInterval(3 * 3600)
    static let weeklyWindow = now.addingTimeInterval(3 * 86_400)

    static func bar(
        _ kind: UsageSnapshot.Bar.Kind,
        _ title: String,
        _ fraction: Double,
        _ resetsAt: Date?
    ) -> UsageSnapshot.Bar {
        UsageSnapshot.Bar(
            id: kind,
            title: title,
            fraction: fraction,
            percentLabel: "\(Int((fraction * 100).rounded()))%",
            resetsAt: resetsAt
        )
    }
}

extension UsageSnapshot {
    static func snapshot(
        session: Double = 0.1,
        sessionResetsAt: Date? = TestSnapshots.sessionWindow,
        weekly: Double = 0.1,
        weeklyResetsAt: Date? = TestSnapshots.weeklyWindow,
        fable: Double? = nil,
        fableResetsAt: Date? = TestSnapshots.weeklyWindow
    ) -> UsageSnapshot {
        UsageSnapshot(
            session: TestSnapshots.bar(.session, "Current Session", session, sessionResetsAt),
            weekly: TestSnapshots.bar(.weekly, "Weekly Limit", weekly, weeklyResetsAt),
            scopedWeekly: fable.map { TestSnapshots.bar(.scopedWeekly, "Fable", $0, fableResetsAt) },
            extraUsage: nil,
            fetchedAt: TestSnapshots.now
        )
    }
}
