//
//  UsageStoreResetsTests.swift
//  ClaudeUsageTests
//
//  The store's resets request: it follows a successful usage fetch when the
//  policy says it's due, and its failures never touch the bars.
//

import Foundation
import Testing
@testable import ClaudeUsage

@Suite("UsageStore limit resets")
struct UsageStoreResetsTests {

    @Test("the first success fetches the resets with the token and the installed version")
    func firstSuccessFetches() async {
        let harness = StoreHarness()
        let store = harness.makeStore()

        await store.refresh(trigger: .manual)

        #expect(harness.resets.calls.map(\.token) == ["token-1"])
        #expect(harness.resets.calls.map(\.version) == ["2.1.322"])
        #expect(store.limitResets?.grants.map(\.id) == ["weekly"])
        #expect(store.limitResetsCheckedAt == harness.clock.now)
        #expect(store.limitResetsUnavailableReason == nil)
        #expect(store.networkRequestCount == 2)
    }

    @Test("another success inside the hour doesn't ask again; one an hour later does")
    func hourlyCadence() async {
        let harness = StoreHarness()
        let store = harness.makeStore()
        await store.refresh(trigger: .manual)

        harness.clock.advance(30 * 60)
        await store.refresh(trigger: .manual)
        #expect(harness.resets.calls.count == 1)

        harness.clock.advance(30 * 60)
        await store.refresh(trigger: .manual)
        #expect(harness.resets.calls.count == 2)
    }

    @Test("a dropped bar asks again after five minutes")
    func afterChange() async {
        let harness = StoreHarness()
        let store = harness.makeStore()
        harness.fetcher.responses = [.success(.sample(weekly: 90)), .success(.sample(weekly: 0))]
        await store.refresh(trigger: .manual)

        harness.clock.advance(5 * 60)
        await store.refresh(trigger: .manual)

        #expect(harness.resets.calls.count == 2)
    }

    @Test("an ineligible account has no resets and records why")
    func ineligible() async {
        let harness = StoreHarness()
        harness.resets.responses = [.success(LimitResetsBlock(eligible: false, ineligibleReason: "surface", grants: []))]
        let store = harness.makeStore()

        await store.refresh(trigger: .manual)

        #expect(store.limitResets == nil)
        #expect(store.limitResetsUnavailableReason == "surface")
    }

    @Test("without a claude version nothing is sent")
    func noVersion() async {
        let harness = StoreHarness()
        harness.cliVersion.value = nil
        let store = harness.makeStore()

        await store.refresh(trigger: .manual)

        #expect(harness.resets.calls.isEmpty)
        #expect(store.limitResets == nil)
        #expect(store.limitResetsUnavailableReason == "claude version unknown")
        #expect(store.networkRequestCount == 1)
    }

    @Test("a failed resets request keeps the last resets and leaves the usage alone")
    func failureKeepsResets() async {
        let harness = StoreHarness()
        harness.resets.responses = [.success(.eligibleSample()), .failure(.rateLimited(retryAfter: 60))]
        let store = harness.makeStore()
        await store.refresh(trigger: .manual)

        harness.clock.advance(60 * 60)
        await store.refresh(trigger: .manual)

        #expect(harness.resets.calls.count == 2)
        #expect(store.limitResets?.grants.map(\.id) == ["weekly"])
        #expect(store.failure == nil)
        #expect(store.rateLimitedUntil == nil)
        #expect(store.snapshot != nil)
    }

    @Test("a failed usage fetch never asks for resets")
    func usageFailure() async {
        let harness = StoreHarness()
        harness.fetcher.responses = [.failure(.http(503))]
        let store = harness.makeStore()

        await store.refresh(trigger: .manual)

        #expect(harness.resets.calls.isEmpty)
        #expect(harness.notifier.evaluatedResets.isEmpty)
    }

    @Test("each success hands the resets to the notifier once they've been checked")
    func notifies() async {
        let harness = StoreHarness()
        harness.resets.responses = [.failure(.http(500)), .success(.eligibleSample())]
        let store = harness.makeStore()

        await store.refresh(trigger: .manual)
        #expect(harness.notifier.evaluatedResets.isEmpty)

        harness.clock.advance(60 * 60)
        await store.refresh(trigger: .manual)
        harness.clock.advance(60)
        await store.refresh(trigger: .manual)
        #expect(harness.notifier.evaluatedResets.map { $0.grants.map(\.id) } == [["weekly"], ["weekly"]])
    }

    @Test("the simulated reset reaches the notifier while it's switched on")
    func simulatedReachesNotifier() async {
        let harness = StoreHarness()
        harness.defaults.set(true, forKey: SettingsKeys.simulateLimitReset.name)
        harness.resets.responses = [.success(LimitResetsBlock(eligible: false, ineligibleReason: "surface", grants: []))]
        let store = harness.makeStore()

        await store.refresh(trigger: .manual)

        #expect(harness.notifier.evaluatedResets.map { $0.grants.map(\.id) } == [["simulated-weekly-reset"]])
    }
}
