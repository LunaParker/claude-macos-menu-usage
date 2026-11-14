//
//  LimitResetsTests.swift
//  ClaudeUsageTests
//
//  Which grants count as held resets, which bars each applies to, and which
//  ones each "Show limit resets" choice surfaces.
//

import Foundation
import Testing
@testable import ClaudeUsage

enum ResetFixtures {
    /// 2026-11-13 18:00 UTC, 1:00 PM in Toronto, a Friday.
    static let now = Date(timeIntervalSince1970: 1_794_592_800)
    static let timeZone = TimeZone(identifier: "America/Toronto")!
    static let locale = Locale(identifier: "en_US")
    /// Dec 10, 2026 5:00 PM in Toronto.
    static let weeklyExpiry = Date(timeIntervalSince1970: 1_796_940_000)
    /// Mar 9, 2027 2:59 AM in Toronto.
    static let fableExpiry = Date(timeIntervalSince1970: 1_804_579_140)

    static let weekly = LimitResets.Grant(id: "weekly", count: 1, expiresAt: weeklyExpiry, clears: [.weekly, .scopedWeekly])
    static let fableA = LimitResets.Grant(id: "fable-a", count: 1, expiresAt: fableExpiry, clears: [.scopedWeekly])
    static let fableB = LimitResets.Grant(id: "fable-b", count: 1, expiresAt: fableExpiry, clears: [.scopedWeekly])
    static let all = LimitResets(grants: [weekly, fableA, fableB])

    static func wire(
        id: String = "g",
        resetsLeft: Int? = 1,
        startsAt: Date? = nil,
        endsAt: Date? = weeklyExpiry,
        clears: [String]? = ["seven_day"],
        paused: Bool? = false,
        usableNow: Bool? = true
    ) -> LimitResetsBlock.Grant {
        LimitResetsBlock.Grant(id: id, resetsLeft: resetsLeft, startsAt: startsAt, endsAt: endsAt, clears: clears, paused: paused, usableNow: usableNow)
    }

    static func snapshot(weekly: Double, fable: Double?, session: Double? = nil, resetsAt: Date? = nil) -> UsageSnapshot {
        let reset = resetsAt ?? now.addingTimeInterval(2 * 86_400 + 9 * 3600)
        return UsageSnapshot(
            session: session.map { TestSnapshots.bar(.session, "Current Session", $0, now.addingTimeInterval(3600)) },
            weekly: TestSnapshots.bar(.weekly, "Weekly Limit", weekly, reset),
            scopedWeekly: fable.map { TestSnapshots.bar(.scopedWeekly, "Fable", $0, reset) },
            extraUsage: nil,
            fetchedAt: now
        )
    }
}

@Suite("LimitResets")
struct LimitResetsTests {
    typealias F = ResetFixtures

    @Test("maps the API's limit keys to the bars")
    func limitKeys() {
        #expect(LimitResets.barKind(forLimitKey: "five_hour") == .session)
        #expect(LimitResets.barKind(forLimitKey: "seven_day") == .weekly)
        #expect(LimitResets.barKind(forLimitKey: "seven_day_overage_included") == .scopedWeekly)
        #expect(LimitResets.barKind(forLimitKey: "seven_day_opus") == nil)
    }

    @Test("keeps only resets that are held, started, unexpired, usable and clear a known limit")
    func heldGrants() {
        let block = LimitResetsBlock(eligible: true, ineligibleReason: nil, grants: [
            F.wire(id: "ok", clears: ["seven_day", "seven_day_overage_included", "something_new"]),
            F.wire(id: "used", resetsLeft: 0),
            F.wire(id: "no-count", resetsLeft: nil),
            F.wire(id: "expired", endsAt: F.now.addingTimeInterval(-1)),
            F.wire(id: "not-started", startsAt: F.now.addingTimeInterval(60)),
            F.wire(id: "paused", paused: true),
            F.wire(id: "cooling-down", usableNow: false),
            F.wire(id: "unknown-limit", clears: ["something_new"]),
            F.wire(id: "no-expiry", endsAt: nil, paused: nil, usableNow: nil),
        ])

        let resets = LimitResets(block: block, now: F.now)

        #expect(resets.grants.map(\.id) == ["ok", "no-expiry"])
        #expect(resets.grants[0].clears == [.weekly, .scopedWeekly])
        #expect(resets.grants[0].expiresAt == F.weeklyExpiry)
    }

    @Test("Always surfaces every reset and Never none")
    func alwaysAndNever() {
        let snapshot = F.snapshot(weekly: 0.43, fable: 0.02)
        #expect(F.all.surfaced(in: snapshot, visibility: .always, now: F.now).map(\.id) == ["weekly", "fable-a", "fable-b"])
        #expect(F.all.surfaced(in: snapshot, visibility: .never, now: F.now).isEmpty)
    }

    @Test("From 75% follows only the bars each reset clears: Fable resets stay with the Fable bar")
    func nearLimitWeekly() {
        let snapshot = F.snapshot(weekly: 0.78, fable: 0.12)
        #expect(F.all.surfaced(in: snapshot, visibility: .nearLimit, now: F.now).map(\.id) == ["weekly"])
    }

    @Test("a nearly full Fable bar surfaces the Fable resets and the weekly one, which clears Fable too")
    func nearLimitFable() {
        let snapshot = F.snapshot(weekly: 0.40, fable: 0.80)
        #expect(F.all.surfaced(in: snapshot, visibility: .nearLimit, now: F.now).map(\.id) == ["weekly", "fable-a", "fable-b"])
    }

    @Test("75% exactly counts; 74% doesn't")
    func nearLimitBoundary() {
        #expect(F.all.surfaced(in: F.snapshot(weekly: 0.75, fable: 0), visibility: .nearLimit, now: F.now).map(\.id) == ["weekly"])
        #expect(F.all.surfaced(in: F.snapshot(weekly: 0.74, fable: 0), visibility: .nearLimit, now: F.now).isEmpty)
    }

    @Test("At the limit needs a cleared bar at 100%")
    func atLimit() {
        #expect(F.all.surfaced(in: F.snapshot(weekly: 0.99, fable: 0.99), visibility: .atLimit, now: F.now).isEmpty)
        #expect(F.all.surfaced(in: F.snapshot(weekly: 1, fable: 0.38), visibility: .atLimit, now: F.now).map(\.id) == ["weekly"])
    }

    @Test("a reset for a bar the plan doesn't have only shows under Always")
    func absentBar() {
        let session = LimitResets(grants: [LimitResets.Grant(id: "s", count: 1, expiresAt: nil, clears: [.session])])
        let snapshot = F.snapshot(weekly: 1, fable: 1)
        #expect(session.surfaced(in: snapshot, visibility: .atLimit, now: F.now).isEmpty)
        #expect(session.surfaced(in: snapshot, visibility: .always, now: F.now).map(\.id) == ["s"])
    }

    @Test("a reset that expired since the last check isn't surfaced")
    func expiredSinceFetch() {
        let later = F.weeklyExpiry.addingTimeInterval(1)
        #expect(F.all.surfaced(in: F.snapshot(weekly: 0.4, fable: 0), visibility: .always, now: later).map(\.id) == ["fable-a", "fable-b"])
    }

    @Test("the simulation adds a weekly reset that expires eight days after the start of today")
    func simulated() throws {
        let shown = try #require(LimitResets.displayed(F.all, simulate: true, now: F.now, timeZone: F.timeZone))
        let fake = try #require(shown.grants.last)
        #expect(shown.grants.count == 4)
        #expect(fake.isSimulated)
        #expect(fake.clears == [.weekly])
        #expect(fake.count == 1)
        // Nov 21, 2026 midnight in Toronto.
        #expect(fake.expiresAt == Date(timeIntervalSince1970: 1_795_237_200))
        #expect(LimitResets.displayed(F.all, simulate: false, now: F.now) == F.all)
        #expect(LimitResets.displayed(nil, simulate: false, now: F.now) == nil)
        #expect(LimitResets.displayed(nil, simulate: true, now: F.now)?.grants.count == 1)
    }
}
