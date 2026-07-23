//
//  BuildSnapshotTests.swift
//  ClaudeUsageTests
//
//  Covers `UsageStore.buildSnapshot`. Most of the function's complexity is
//  in the conditional inclusion of the model-scoped weekly bar (presence-
//  gated on the `limits` array) and the Extra Usage card (requires four
//  populated fields). These tests pin every "this gets hidden" branch.
//

import Foundation
import Testing
@testable import ClaudeUsage

@Suite("UsageStore.buildSnapshot")
struct BuildSnapshotTests {

    // MARK: Always-present bars

    @Test("session and weekly bars are always built")
    func sessionAndWeeklyAlwaysPresent() {
        let response = makeResponse(
            fiveHour: .init(utilization: 42, resetsAt: nil),
            sevenDay: .init(utilization: 17, resetsAt: nil)
        )
        let snapshot = UsageStore.buildSnapshot(from: response)

        #expect(snapshot.session.fraction == 0.42)
        #expect(snapshot.weekly.fraction == 0.17)
    }

    @Test("nil utilisation collapses to a zero-fraction bar")
    func nilUtilisationIsZero() {
        let response = makeResponse(
            fiveHour: .init(utilization: nil, resetsAt: nil),
            sevenDay: .init(utilization: nil, resetsAt: nil)
        )
        let snapshot = UsageStore.buildSnapshot(from: response)

        #expect(snapshot.session.fraction == 0)
        #expect(snapshot.weekly.fraction == 0)
    }

    @Test("utilisation above 100 is clamped to 1.0")
    func utilisationClampedHigh() {
        let response = makeResponse(
            fiveHour: .init(utilization: 150, resetsAt: nil),
            sevenDay: .init(utilization: 100, resetsAt: nil)
        )
        let snapshot = UsageStore.buildSnapshot(from: response)

        #expect(snapshot.session.fraction == 1)
        #expect(snapshot.weekly.fraction == 1)
    }

    @Test("negative utilisation is clamped to 0")
    func utilisationClampedLow() {
        let response = makeResponse(
            fiveHour: .init(utilization: -10, resetsAt: nil),
            sevenDay: .init(utilization: 50, resetsAt: nil)
        )
        let snapshot = UsageStore.buildSnapshot(from: response)

        #expect(snapshot.session.fraction == 0)
    }

    // MARK: Model-scoped weekly bar (Fable)

    @Test("scoped weekly bar appears when the API returns a weekly_scoped limit")
    func scopedWeeklyIncludedWhenPresent() {
        let response = makeResponse(limits: [fableLimit()])
        let snapshot = UsageStore.buildSnapshot(from: response)

        #expect(snapshot.scopedWeekly?.title == "Fable")
        #expect(snapshot.scopedWeekly?.fraction == 0.30)
    }

    @Test("scoped weekly bar hidden when the limits array is absent")
    func scopedWeeklyHiddenWithoutLimits() {
        let snapshot = UsageStore.buildSnapshot(from: makeResponse())

        #expect(snapshot.scopedWeekly == nil)
    }

    @Test("scoped weekly bar hidden when no entry has kind weekly_scoped")
    func scopedWeeklyHiddenWithoutScopedKind() {
        let response = makeResponse(limits: [
            LimitEntry(kind: "session", percent: 27, resetsAt: nil, scope: nil),
            LimitEntry(kind: "weekly_all", percent: 19, resetsAt: nil, scope: nil),
        ])
        let snapshot = UsageStore.buildSnapshot(from: response)

        #expect(snapshot.scopedWeekly == nil)
    }

    @Test("scoped weekly bar hidden when the entry lacks a model display name")
    func scopedWeeklyHiddenWithoutDisplayName() {
        let response = makeResponse(limits: [
            LimitEntry(kind: "weekly_scoped", percent: 30, resetsAt: nil, scope: nil)
        ])
        let snapshot = UsageStore.buildSnapshot(from: response)

        #expect(snapshot.scopedWeekly == nil)
    }

    @Test("nil percent collapses to a zero-fraction scoped bar")
    func scopedWeeklyNilPercentIsZero() {
        let response = makeResponse(limits: [fableLimit(percent: nil)])
        let snapshot = UsageStore.buildSnapshot(from: response)

        #expect(snapshot.scopedWeekly?.fraction == 0)
    }

    @Test("limits array decodes from the wire format")
    func limitsDecodeFromWire() throws {
        let json = """
        {
          "five_hour": null,
          "seven_day": null,
          "limits": [
            { "kind": "weekly_scoped", "group": "weekly", "percent": 30,
              "severity": "normal", "resets_at": null,
              "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null },
              "is_active": true }
          ]
        }
        """
        let response = try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
        let snapshot = UsageStore.buildSnapshot(from: response)

        #expect(snapshot.scopedWeekly?.title == "Fable")
        #expect(snapshot.scopedWeekly?.fraction == 0.30)
    }

    // MARK: peakUtilization

    // peakUtilization drives the menu bar icon variant — getting it wrong
    // would show a green icon on a 90%-used session.
    @Test("peakUtilization reflects the highest bar")
    func peakAcrossBars() {
        let response = makeResponse(
            fiveHour: .init(utilization: 80, resetsAt: nil),
            sevenDay: .init(utilization: 20, resetsAt: nil)
        )
        let snapshot = UsageStore.buildSnapshot(from: response)

        #expect(snapshot.peakUtilization == 0.8)
    }

    @Test("peakUtilization includes the scoped weekly bar")
    func peakIncludesScopedWeekly() {
        let response = makeResponse(
            fiveHour: .init(utilization: 10, resetsAt: nil),
            sevenDay: .init(utilization: 5, resetsAt: nil),
            limits: [fableLimit(percent: 30)]
        )
        let snapshot = UsageStore.buildSnapshot(from: response)

        #expect(snapshot.peakUtilization == 0.30)
    }

    // Pins the documented design choice on `UsageSnapshot.peakUtilization`:
    // Extra Usage represents paid overflow, not remaining free quota, so
    // folding it into the peak (and therefore the menu bar icon variant)
    // would send the wrong signal. Without this test, someone could
    // include extraUsage in the peak and every other test would stay
    // green.
    @Test("peakUtilization excludes Extra Usage by design")
    func peakIgnoresExtraUsage() {
        let response = makeResponse(
            fiveHour: .init(utilization: 20, resetsAt: nil),
            sevenDay: .init(utilization: 20, resetsAt: nil),
            extraUsage: .init(isEnabled: true, monthlyLimit: 100, usedCredits: 95, utilization: 95)
        )
        let snapshot = UsageStore.buildSnapshot(from: response)

        #expect(snapshot.extraUsage != nil)
        #expect(snapshot.peakUtilization == 0.2)
    }

    // MARK: Extra Usage card

    @Test("Extra Usage card included when all four fields are populated")
    func extraUsageIncludedWhenComplete() {
        let response = makeResponse(
            extraUsage: .init(isEnabled: true, monthlyLimit: 100, usedCredits: 38, utilization: 38)
        )
        let snapshot = UsageStore.buildSnapshot(from: response)

        #expect(snapshot.extraUsage != nil)
        #expect(snapshot.extraUsage?.fraction == 0.38)
        #expect(snapshot.extraUsage?.used == 38)
        #expect(snapshot.extraUsage?.monthlyLimit == 100)
        #expect(snapshot.extraUsage?.remaining == 62)
    }

    @Test("Extra Usage hidden when isEnabled is false")
    func extraUsageHiddenWhenDisabled() {
        let response = makeResponse(
            extraUsage: .init(isEnabled: false, monthlyLimit: 100, usedCredits: 38, utilization: 38)
        )
        let snapshot = UsageStore.buildSnapshot(from: response)

        #expect(snapshot.extraUsage == nil)
    }

    @Test("Extra Usage hidden when monthlyLimit is nil")
    func extraUsageHiddenWithoutLimit() {
        let response = makeResponse(
            extraUsage: .init(isEnabled: true, monthlyLimit: nil, usedCredits: 38, utilization: 38)
        )
        let snapshot = UsageStore.buildSnapshot(from: response)

        #expect(snapshot.extraUsage == nil)
    }

    @Test("Extra Usage hidden when monthlyLimit is zero (avoids divide-by-zero in card)")
    func extraUsageHiddenWithZeroLimit() {
        let response = makeResponse(
            extraUsage: .init(isEnabled: true, monthlyLimit: 0, usedCredits: 0, utilization: 0)
        )
        let snapshot = UsageStore.buildSnapshot(from: response)

        #expect(snapshot.extraUsage == nil)
    }

    @Test("Extra Usage hidden when usedCredits is nil")
    func extraUsageHiddenWithoutUsed() {
        let response = makeResponse(
            extraUsage: .init(isEnabled: true, monthlyLimit: 100, usedCredits: nil, utilization: 0)
        )
        let snapshot = UsageStore.buildSnapshot(from: response)

        #expect(snapshot.extraUsage == nil)
    }

    @Test("Extra Usage hidden when utilisation is nil")
    func extraUsageHiddenWithoutUtilization() {
        let response = makeResponse(
            extraUsage: .init(isEnabled: true, monthlyLimit: 100, usedCredits: 38, utilization: nil)
        )
        let snapshot = UsageStore.buildSnapshot(from: response)

        #expect(snapshot.extraUsage == nil)
    }

    @Test("Extra Usage `remaining` is clamped at zero when over-spent")
    func extraUsageRemainingClamped() {
        let response = makeResponse(
            extraUsage: .init(isEnabled: true, monthlyLimit: 100, usedCredits: 130, utilization: 100)
        )
        let snapshot = UsageStore.buildSnapshot(from: response)

        #expect(snapshot.extraUsage?.remaining == 0)
    }

    // MARK: Fixtures

    private func makeResponse(
        fiveHour: UsageWindow? = .init(utilization: 0, resetsAt: nil),
        sevenDay: UsageWindow? = .init(utilization: 0, resetsAt: nil),
        limits: [LimitEntry]? = nil,
        extraUsage: ExtraUsageResponse? = nil
    ) -> UsageResponse {
        UsageResponse(
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            sevenDayOpus: nil,
            limits: limits,
            extraUsage: extraUsage
        )
    }

    /// A `weekly_scoped` limits entry shaped like the API returns for the
    /// Fable quota on Max plans.
    private func fableLimit(percent: Double? = 30) -> LimitEntry {
        LimitEntry(
            kind: "weekly_scoped",
            percent: percent,
            resetsAt: nil,
            scope: .init(model: .init(displayName: "Fable"))
        )
    }
}
