//
//  UsageStoreSleepTests.swift
//  ClaudeUsageTests
//
//  The Mac wakes briefly from sleep every 10 to 20 minutes (DarkWake), and
//  the poll timer fires in those wakes. Sep 30 to Oct 6, 20% of requests
//  were made that way, nobody saw them, and 8 of 10 background refreshes
//  were launched into one and frozen for 5 to 17 minutes. While the displays
//  are asleep the store does nothing, then fetches once they wake.
//

import Foundation
import Testing
@testable import ClaudeUsage

@Suite("UsageStore and display sleep")
struct UsageStoreSleepTests {

    @Test("while the displays sleep, polls, retries and checks touch neither the Keychain nor the network")
    func asleepDoesNothing() async {
        let harness = StoreHarness()
        harness.display.sleep()
        let store = harness.makeStore()

        await store.refresh(trigger: .poll)
        await store.refresh(trigger: .retry)
        await store.refresh(trigger: .postRefresh)

        #expect(harness.keychain.loads == 0)
        #expect(harness.fetcher.tokens.isEmpty)
    }

    @Test("an expired token found during sleep isn't refreshed until the displays wake")
    func noRefreshLaunchWhileAsleep() async {
        let harness = StoreHarness()
        harness.keychain.next = .success(TestCredentials.valid(expiresIn: -60))
        harness.display.sleep()
        let store = harness.makeStore()

        await store.refresh(trigger: .poll)
        #expect(harness.refresher.starts.isEmpty)

        harness.display.wake()
        await harness.scheduler.runPending()
        #expect(harness.refresher.starts.count == 1)
    }

    @Test("waking the displays fetches five seconds later")
    func wakeFetches() async {
        let harness = StoreHarness()
        harness.display.sleep()
        let store = harness.makeStore()
        await store.refresh(trigger: .poll)

        harness.display.wake()

        #expect(harness.scheduler.pendingDelays == [.seconds(5)])
        await harness.scheduler.runPending()
        #expect(harness.fetcher.tokens.count == 1)
        #expect(store.snapshot != nil)
    }

    @Test("a wake before onboarding is finished reads nothing")
    func noWakeFetchBeforeOnboarding() {
        let harness = StoreHarness()
        harness.defaults.set(false, forKey: SettingsKeys.hasCompletedOnboarding.name)
        _ = harness.makeStore()

        harness.display.wake()

        #expect(harness.scheduler.pendingDelays.isEmpty)
    }

    @Test("a manual refresh still runs with the displays asleep")
    func manualIgnoresSleep() async {
        let harness = StoreHarness()
        harness.display.sleep()
        let store = harness.makeStore()

        await store.refresh(trigger: .manual)

        #expect(harness.fetcher.tokens.count == 1)
    }

    @Test("opening the popover within a minute of a success doesn't fetch again")
    func popoverDebounce() async {
        let harness = StoreHarness()
        let store = harness.makeStore()
        await store.refresh(trigger: .poll)

        harness.clock.advance(59)
        await store.refresh(trigger: .popover)
        #expect(harness.fetcher.tokens.count == 1)

        harness.clock.advance(2)
        await store.refresh(trigger: .popover)
        #expect(harness.fetcher.tokens.count == 2)
    }
}
