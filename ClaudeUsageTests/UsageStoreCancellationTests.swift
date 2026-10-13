//
//  UsageStoreCancellationTests.swift
//  ClaudeUsageTests
//
//  Cancelling the task that runs a refresh (a Shortcut stopped mid-run)
//  must not read as the network failing.
//

import Foundation
import Testing
@testable import ClaudeUsage

@Suite("UsageStore cancellation")
struct UsageStoreCancellationTests {

    @Test("a cancelled request is not a network failure")
    func cancelledRequestIsNotOffline() async {
        let harness = StoreHarness()
        let store = harness.makeStore()
        harness.fetcher.responses = [.failure(.transport(URLError(.cancelled)))]

        await store.refresh(trigger: .poll)

        #expect(store.failure == nil)
        #expect(harness.scheduler.pendingDelays.isEmpty)
    }
}
