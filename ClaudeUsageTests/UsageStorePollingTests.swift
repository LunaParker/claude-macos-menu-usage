//
//  UsageStorePollingTests.swift
//  ClaudeUsageTests
//
//  The poll timer. A success from any trigger pushes the next poll back a
//  full interval, so a popover open replaces a poll instead of adding one:
//  at 3 minutes plus popover opens (29–33 requests an hour) the endpoint
//  answered 429 four times in two days, once with Retry-After: 3600.
//

import Foundation
import Testing
@testable import ClaudeUsage

@Suite("UsageStore polling")
struct UsageStorePollingTests {

    @Test("starting polling fetches now and books the next poll one interval out")
    func startFetchesThenSchedules() async {
        let harness = StoreHarness()
        let store = harness.makeStore()

        store.startPolling()
        await harness.scheduler.runDue()

        #expect(harness.fetcher.tokens.count == 1)
        #expect(harness.scheduler.pendingDelays == [.seconds(300)])
    }

    @Test("a popover fetch pushes the next poll back a full interval")
    func successResetsPoll() async {
        let harness = StoreHarness()
        let store = harness.makeStore()
        store.startPolling()
        await harness.scheduler.runDue()

        harness.clock.advance(200)
        await store.refresh(trigger: .popover)
        #expect(harness.fetcher.tokens.count == 2)

        // 400 s in: the poll booked at the start, due at 300 s, must not fire.
        harness.clock.advance(200)
        await harness.scheduler.runDue()
        #expect(harness.fetcher.tokens.count == 2)

        // 500 s in: one interval after the popover fetch.
        harness.clock.advance(100)
        await harness.scheduler.runDue()
        #expect(harness.fetcher.tokens.count == 3)
    }

    @Test("a poll that fails transiently books the quick retry and the next poll")
    func failureKeepsPolling() async {
        let harness = StoreHarness()
        let store = harness.makeStore()
        harness.fetcher.responses = [.failure(.http(503))]

        store.startPolling()
        await harness.scheduler.runDue()

        #expect(harness.scheduler.pendingDelays == [.seconds(30), .seconds(300)])
    }

    @Test("a changed interval rebooks the next poll from now, without fetching")
    func rescheduleUsesNewInterval() async {
        let harness = StoreHarness()
        let store = harness.makeStore()
        store.startPolling()
        await harness.scheduler.runDue()

        harness.defaults.set(600, forKey: SettingsKeys.pollIntervalSeconds.name)
        store.reschedulePolling()

        #expect(harness.scheduler.pendingDelays == [.seconds(600)])
        #expect(harness.fetcher.tokens.count == 1)
    }

    @Test("stopping polling cancels the next poll, and a later fetch books none")
    func stopCancels() async {
        let harness = StoreHarness()
        let store = harness.makeStore()
        store.startPolling()
        await harness.scheduler.runDue()

        store.stopPolling()
        #expect(harness.scheduler.pendingDelays.isEmpty)

        await store.refresh(trigger: .manual)
        #expect(harness.scheduler.pendingDelays.isEmpty)
    }

    @Test("a second start while polling is a no-op")
    func startIsIdempotent() async {
        let harness = StoreHarness()
        let store = harness.makeStore()

        store.startPolling()
        store.startPolling()
        await harness.scheduler.runDue()

        #expect(harness.fetcher.tokens.count == 1)
        #expect(harness.scheduler.pendingDelays == [.seconds(300)])
    }

    /// With the live scheduler the poll runs inside the task that was booked
    /// for it; rebooking on success must not cancel that task, or a rerun
    /// queued during the poll fetches in a cancelled task and dies.
    @Test("a poll's own success doesn't cancel the task still running it")
    func pollSurvivesItsOwnSuccess() async {
        let harness = StoreHarness()
        let store = harness.makeStore(scheduler: LiveScheduler())
        harness.fetcher.delay = .milliseconds(200)

        store.startPolling()
        for _ in 0..<100 where !store.isRefreshing {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.isRefreshing)
        await store.refresh(trigger: .manual)  // queued as a rerun

        for _ in 0..<100 where harness.notifier.evaluated.count < 2 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(harness.notifier.evaluated.count == 2)
        store.stopPolling()
    }
}
