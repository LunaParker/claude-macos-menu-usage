//
//  UsageStoreFetchTests.swift
//  ClaudeUsageTests
//
//  How UsageStore applies each fetch outcome. A transient failure (offline,
//  a server error, a 429) keeps the last bars on screen and retries soon; a
//  failure that needs the user replaces them.
//

import Foundation
import Testing
@testable import ClaudeUsage

@Suite("UsageStore fetch outcomes")
struct UsageStoreFetchTests {

    @Test("a successful fetch shows the bars, clears the failure and evaluates alerts")
    func success() async {
        let harness = StoreHarness()
        let store = harness.makeStore()

        await store.refresh()

        #expect(store.snapshot?.session.fraction == 0.42)
        #expect(store.failure == nil)
        #expect(store.lastUpdated == harness.clock.now)
        #expect(harness.notifier.evaluated.count == 1)
    }

    @Test("a network error keeps the last bars and schedules a quick retry")
    func offlineKeepsSnapshot() async {
        let harness = StoreHarness()
        let store = harness.makeStore()
        await store.refresh()

        harness.fetcher.responses = [.failure(.transport(URLError(.notConnectedToInternet)))]
        await store.refresh()

        #expect(store.snapshot?.session.fraction == 0.42)
        guard case .offline = store.failure else {
            Issue.record("expected .offline, got \(String(describing: store.failure))")
            return
        }
        #expect(harness.scheduler.pendingDelays == [.seconds(30)])
    }

    @Test("the quick retry fetches again and a success cancels further retries")
    func retryRecovers() async {
        let harness = StoreHarness()
        let store = harness.makeStore()
        harness.fetcher.responses = [.failure(.http(503)), .success(.sample(session: 50))]

        await store.refresh()
        #expect(store.failure == .server(status: 503))

        await harness.scheduler.runPending()

        #expect(store.snapshot?.session.fraction == 0.5)
        #expect(store.failure == nil)
        #expect(harness.scheduler.pendingDelays.isEmpty)
    }

    @Test("quick retries back off but never wait longer than the poll interval")
    func retryBackoff() {
        let poll = Duration.seconds(180)

        #expect(UsageStore.transientRetryDelay(afterFailures: 1, pollInterval: poll) == .seconds(30))
        #expect(UsageStore.transientRetryDelay(afterFailures: 2, pollInterval: poll) == .seconds(60))
        #expect(UsageStore.transientRetryDelay(afterFailures: 3, pollInterval: poll) == .seconds(120))
        #expect(UsageStore.transientRetryDelay(afterFailures: 4, pollInterval: poll) == .seconds(180))
        #expect(UsageStore.transientRetryDelay(afterFailures: 9, pollInterval: poll) == .seconds(180))
    }

    @Test("a 429 keeps the bars and starts the cooldown from Retry-After")
    func rateLimited() async {
        let harness = StoreHarness()
        let store = harness.makeStore()
        await store.refresh()

        harness.fetcher.responses = [.failure(.rateLimited(retryAfter: 3600))]
        await store.refresh()

        let until = harness.clock.now.addingTimeInterval(3600)
        #expect(store.snapshot != nil)
        #expect(store.rateLimitedUntil == until)
        #expect(store.failure == .rateLimited(until: until))
    }

    @Test("during a cooldown a refresh doesn't reach the network")
    func cooldownBlocksRequests() async {
        let harness = StoreHarness()
        let store = harness.makeStore()
        harness.fetcher.responses = [.failure(.rateLimited(retryAfter: 120))]
        await store.refresh()

        harness.clock.advance(60)
        await store.refresh()

        #expect(harness.fetcher.tokens.count == 1)
    }

    @Test("a rejected token is retried silently with a newer token from the Keychain")
    func rotation() async {
        let harness = StoreHarness()
        let store = harness.makeStore()
        await store.refresh()

        harness.fetcher.responses = [.failure(.unauthorized), .success(.sample(session: 60))]
        harness.keychain.next = .success(TestCredentials.valid(token: "token-2"))
        await store.refresh()

        #expect(harness.fetcher.tokens == ["token-1", "token-1", "token-2"])
        #expect(store.snapshot?.session.fraction == 0.6)
        #expect(store.failure == nil)
        #expect(harness.notifier.lost == 0)
    }

    @Test("no credentials anywhere means signed out, and the user is told")
    func signedOut() async {
        let harness = StoreHarness()
        harness.keychain.next = .failure(.itemNotFound)
        let store = harness.makeStore()

        await store.refresh()

        #expect(store.failure == .signedOut)
        #expect(store.presentation == .problem(.signedOut))
        #expect(harness.fetcher.tokens.isEmpty)
    }
}

@Suite("UsagePresentation")
struct UsagePresentationTests {

    private let now = Date()

    @Test("nothing loaded and nothing wrong yet is the loading state")
    func loading() {
        #expect(UsagePresentation(snapshot: nil, failure: nil) == .loading)
    }

    @Test("a transient failure keeps the bars, with the failure as a notice")
    func transientShowsBars() {
        let snapshot = UsageStore.buildSnapshot(from: .sample(), fetchedAt: now)

        #expect(UsagePresentation(snapshot: snapshot, failure: .offline("x")) == .usage(snapshot, notice: .offline("x")))
        #expect(UsagePresentation(snapshot: snapshot, failure: .refreshingSignIn) == .usage(snapshot, notice: .refreshingSignIn))
    }

    @Test("a failure that needs the user replaces the bars")
    func blockingHidesBars() {
        let snapshot = UsageStore.buildSnapshot(from: .sample(), fetchedAt: now)

        #expect(UsagePresentation(snapshot: snapshot, failure: .signedOut) == .problem(.signedOut))
        #expect(UsagePresentation(snapshot: snapshot, failure: .claudeNotFound) == .problem(.claudeNotFound))
    }

    @Test("a failure before any data is shown on its own")
    func failureWithoutData() {
        #expect(UsagePresentation(snapshot: nil, failure: .offline("x")) == .problem(.offline("x")))
    }

    @Test("the menu bar shows recent data through a transient failure, but not data that's too old")
    func menuBarStaleness() {
        let fresh = UsageStore.buildSnapshot(from: .sample(), fetchedAt: now.addingTimeInterval(-10 * 60))
        let old = UsageStore.buildSnapshot(from: .sample(), fetchedAt: now.addingTimeInterval(-31 * 60))

        #expect(UsagePresentation(snapshot: fresh, failure: .offline("x")).menuBarSnapshot(now: now) == fresh)
        #expect(UsagePresentation(snapshot: old, failure: .offline("x")).menuBarSnapshot(now: now) == nil)
        #expect(UsagePresentation(snapshot: fresh, failure: .signedOut).menuBarSnapshot(now: now) == nil)
    }
}
