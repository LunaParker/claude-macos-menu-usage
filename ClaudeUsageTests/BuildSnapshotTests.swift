//
//  BuildSnapshotTests.swift
//  ClaudeUsageTests
//
//  Covers `UsageStore.buildSnapshot`. Most of the function's complexity is
//  in the conditional inclusion of the Sonnet bar (Max-only) and the
//  Extra Usage card (requires four populated fields). These tests pin
//  every "this gets hidden" branch.
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
        let snapshot = UsageStore.buildSnapshot(from: response, credentials: nonMax())

        #expect(snapshot.session.fraction == 0.42)
        #expect(snapshot.weekly.fraction == 0.17)
    }

    @Test("nil utilisation collapses to a zero-fraction bar")
    func nilUtilisationIsZero() {
        let response = makeResponse(
            fiveHour: .init(utilization: nil, resetsAt: nil),
            sevenDay: .init(utilization: nil, resetsAt: nil)
        )
        let snapshot = UsageStore.buildSnapshot(from: response, credentials: nonMax())

        #expect(snapshot.session.fraction == 0)
        #expect(snapshot.weekly.fraction == 0)
    }

    @Test("utilisation above 100 is clamped to 1.0")
    func utilisationClampedHigh() {
        let response = makeResponse(
            fiveHour: .init(utilization: 150, resetsAt: nil),
            sevenDay: .init(utilization: 100, resetsAt: nil)
        )
        let snapshot = UsageStore.buildSnapshot(from: response, credentials: nonMax())

        #expect(snapshot.session.fraction == 1)
        #expect(snapshot.weekly.fraction == 1)
    }

    @Test("negative utilisation is clamped to 0")
    func utilisationClampedLow() {
        let response = makeResponse(
            fiveHour: .init(utilization: -10, resetsAt: nil),
            sevenDay: .init(utilization: 50, resetsAt: nil)
        )
        let snapshot = UsageStore.buildSnapshot(from: response, credentials: nonMax())

        #expect(snapshot.session.fraction == 0)
    }

    // MARK: Sonnet bar (Max-only)

    @Test("Sonnet bar appears for Max subscriber when the API returns the window")
    func sonnetIncludedForMax() {
        let response = makeResponse(
            sevenDaySonnet: .init(utilization: 33, resetsAt: nil)
        )
        let snapshot = UsageStore.buildSnapshot(from: response, credentials: maxSubscription())

        #expect(snapshot.sonnet != nil)
        #expect(snapshot.sonnet?.fraction == 0.33)
    }

    @Test("Sonnet bar is hidden for non-Max accounts even when the API returns it")
    func sonnetHiddenForNonMax() {
        let response = makeResponse(
            sevenDaySonnet: .init(utilization: 33, resetsAt: nil)
        )
        let snapshot = UsageStore.buildSnapshot(from: response, credentials: nonMax())

        #expect(snapshot.sonnet == nil)
    }

    @Test("Sonnet bar is hidden when Max account has no Sonnet window")
    func sonnetHiddenForMaxWithoutWindow() {
        let response = makeResponse(sevenDaySonnet: nil)
        let snapshot = UsageStore.buildSnapshot(from: response, credentials: maxSubscription())

        #expect(snapshot.sonnet == nil)
    }

    // MARK: peakUtilization

    // peakUtilization drives the menu bar icon variant — getting it wrong
    // would show a green icon on a 90%-used session.
    @Test("peakUtilization reflects the highest bar")
    func peakAcrossBars() {
        let response = makeResponse(
            fiveHour: .init(utilization: 80, resetsAt: nil),
            sevenDay: .init(utilization: 20, resetsAt: nil),
            sevenDaySonnet: .init(utilization: 50, resetsAt: nil)
        )
        let snapshot = UsageStore.buildSnapshot(from: response, credentials: maxSubscription())

        #expect(snapshot.peakUtilization == 0.8)
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
            sevenDaySonnet: .init(utilization: 20, resetsAt: nil),
            extraUsage: .init(isEnabled: true, monthlyLimit: 100, usedCredits: 95, utilization: 95)
        )
        let snapshot = UsageStore.buildSnapshot(from: response, credentials: maxSubscription())

        #expect(snapshot.extraUsage != nil)
        #expect(snapshot.peakUtilization == 0.2)
    }

    // MARK: Extra Usage card

    @Test("Extra Usage card included when all four fields are populated")
    func extraUsageIncludedWhenComplete() {
        let response = makeResponse(
            extraUsage: .init(isEnabled: true, monthlyLimit: 100, usedCredits: 38, utilization: 38)
        )
        let snapshot = UsageStore.buildSnapshot(from: response, credentials: nonMax())

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
        let snapshot = UsageStore.buildSnapshot(from: response, credentials: nonMax())

        #expect(snapshot.extraUsage == nil)
    }

    @Test("Extra Usage hidden when monthlyLimit is nil")
    func extraUsageHiddenWithoutLimit() {
        let response = makeResponse(
            extraUsage: .init(isEnabled: true, monthlyLimit: nil, usedCredits: 38, utilization: 38)
        )
        let snapshot = UsageStore.buildSnapshot(from: response, credentials: nonMax())

        #expect(snapshot.extraUsage == nil)
    }

    @Test("Extra Usage hidden when monthlyLimit is zero (avoids divide-by-zero in card)")
    func extraUsageHiddenWithZeroLimit() {
        let response = makeResponse(
            extraUsage: .init(isEnabled: true, monthlyLimit: 0, usedCredits: 0, utilization: 0)
        )
        let snapshot = UsageStore.buildSnapshot(from: response, credentials: nonMax())

        #expect(snapshot.extraUsage == nil)
    }

    @Test("Extra Usage hidden when usedCredits is nil")
    func extraUsageHiddenWithoutUsed() {
        let response = makeResponse(
            extraUsage: .init(isEnabled: true, monthlyLimit: 100, usedCredits: nil, utilization: 0)
        )
        let snapshot = UsageStore.buildSnapshot(from: response, credentials: nonMax())

        #expect(snapshot.extraUsage == nil)
    }

    @Test("Extra Usage hidden when utilisation is nil")
    func extraUsageHiddenWithoutUtilization() {
        let response = makeResponse(
            extraUsage: .init(isEnabled: true, monthlyLimit: 100, usedCredits: 38, utilization: nil)
        )
        let snapshot = UsageStore.buildSnapshot(from: response, credentials: nonMax())

        #expect(snapshot.extraUsage == nil)
    }

    @Test("Extra Usage `remaining` is clamped at zero when over-spent")
    func extraUsageRemainingClamped() {
        let response = makeResponse(
            extraUsage: .init(isEnabled: true, monthlyLimit: 100, usedCredits: 130, utilization: 100)
        )
        let snapshot = UsageStore.buildSnapshot(from: response, credentials: nonMax())

        #expect(snapshot.extraUsage?.remaining == 0)
    }

    // MARK: Fixtures

    private func makeResponse(
        fiveHour: UsageWindow? = .init(utilization: 0, resetsAt: nil),
        sevenDay: UsageWindow? = .init(utilization: 0, resetsAt: nil),
        sevenDaySonnet: UsageWindow? = nil,
        extraUsage: ExtraUsageResponse? = nil
    ) -> UsageResponse {
        UsageResponse(
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            sevenDayOpus: nil,
            sevenDaySonnet: sevenDaySonnet,
            extraUsage: extraUsage
        )
    }

    private func nonMax() -> ClaudeCredentials {
        ClaudeCredentials(
            accessToken: "test",
            refreshToken: "test",
            // Far in the future so `isExpired` is false (not that
            // buildSnapshot reads it, but kept defensive against
            // future changes).
            expiresAt: Int64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000),
            scopes: [],
            subscriptionType: "pro",
            rateLimitTier: nil
        )
    }

    private func maxSubscription() -> ClaudeCredentials {
        ClaudeCredentials(
            accessToken: "test",
            refreshToken: "test",
            expiresAt: Int64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000),
            scopes: [],
            subscriptionType: "max",
            rateLimitTier: nil
        )
    }
}
