//
//  UsageStoreIntentTests.swift
//  ClaudeUsageTests
//
//  `currentUsage(refreshFirst:)` is what the App Intents call: it hands back
//  the data the store has, fetches when there is none or when asked to,
//  waits for a fetch already under way rather than starting another, and
//  fails with something Shortcuts can show.
//

import Foundation
import Testing
@testable import ClaudeUsage

@Suite("UsageStore.currentUsage")
struct UsageStoreIntentTests {

    @Test("returns the data on hand without fetching again")
    func returnsCurrentData() async throws {
        let harness = StoreHarness()
        let store = harness.makeStore()
        await store.refresh(trigger: .poll)

        let snapshot = try await store.currentUsage(refreshFirst: false)

        #expect(snapshot == store.snapshot)
        #expect(harness.fetcher.tokens.count == 1)
    }

    @Test("fetches when there is no data yet")
    func fetchesWhenEmpty() async throws {
        let harness = StoreHarness()
        let store = harness.makeStore()

        let snapshot = try await store.currentUsage(refreshFirst: false)

        #expect(snapshot.session.fraction == 0.42)
        #expect(harness.fetcher.tokens.count == 1)
    }

    @Test("refreshFirst fetches again before answering")
    func refreshFirstFetches() async throws {
        let harness = StoreHarness()
        let store = harness.makeStore()
        await store.refresh(trigger: .poll)
        harness.fetcher.responses = [.success(.sample(session: 77))]

        let snapshot = try await store.currentUsage(refreshFirst: true)

        #expect(snapshot.session.fraction == 0.77)
        #expect(harness.fetcher.tokens.count == 2)
    }

    @Test("a fetch already under way is awaited, not duplicated")
    func waitsForInFlightFetch() async throws {
        let harness = StoreHarness()
        harness.fetcher.delay = .milliseconds(300)
        let store = harness.makeStore()
        let poll = Task { await store.refresh(trigger: .poll) }
        await Task.yield()
        #expect(store.isRefreshing)

        let snapshot = try await store.currentUsage(refreshFirst: false)

        #expect(snapshot.session.fraction == 0.42)
        #expect(harness.fetcher.tokens.count == 1)
        await poll.value
    }

    @Test("before onboarding there is nothing to give")
    func notSetUp() async {
        let harness = StoreHarness()
        harness.defaults.set(false, forKey: SettingsKeys.hasCompletedOnboarding.name)
        let store = harness.makeStore()

        await #expect(throws: UsageRequestError.notSetUp) {
            try await store.currentUsage(refreshFirst: false)
        }
        #expect(harness.keychain.loads == 0)
    }

    @Test("with no data, the store's failure is the error")
    func failureWithoutData() async {
        let harness = StoreHarness()
        harness.keychain.next = .failure(.itemNotFound)
        let store = harness.makeStore()

        await #expect(throws: UsageRequestError.unavailable(.signedOut)) {
            try await store.currentUsage(refreshFirst: false)
        }
    }

    @Test("with data on hand, a failed refresh still answers with the last data")
    func staleDataBeatsFailure() async throws {
        let harness = StoreHarness()
        let store = harness.makeStore()
        await store.refresh(trigger: .poll)
        harness.fetcher.responses = [.failure(.transport(URLError(.notConnectedToInternet)))]

        let snapshot = try await store.currentUsage(refreshFirst: true)

        #expect(snapshot == store.snapshot)
        #expect(store.failure != nil)
    }
}
