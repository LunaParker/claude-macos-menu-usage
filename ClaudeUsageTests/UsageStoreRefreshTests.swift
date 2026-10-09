//
//  UsageStoreRefreshTests.swift
//  ClaudeUsageTests
//
//  The background token refresh as a state machine. When the token expires
//  the store launches one refresh, re-checks once when it exits, backs off
//  when it fails, and tells the user only once both launch methods have
//  failed. A success at any point ends the outage, and a refresh process
//  still running then can't trigger anything when it exits.
//

import Foundation
import Testing
@testable import ClaudeUsage

@Suite("UsageStore background refresh")
struct UsageStoreRefreshTests {

    private let expired = TestCredentials.valid(token: "old", expiresIn: -60)
    private let fresh = TestCredentials.valid(token: "new")

    @Test("an expired token starts one background refresh, without telling the user yet")
    func expiryStartsOneRefresh() async {
        let harness = StoreHarness()
        harness.keychain.next = .success(expired)
        let store = harness.makeStore()

        await store.refresh(trigger: .poll)
        await store.refresh(trigger: .poll)

        #expect(harness.refresher.starts.map(\.attempt) == [1])
        #expect(store.failure == .refreshingSignIn)
        #expect(harness.notifier.lost == 0)
        #expect(harness.fetcher.tokens.isEmpty)
    }

    @Test("when the refresh exits with a working token, the store fetches once and recovers")
    func exitWithFreshToken() async {
        let harness = StoreHarness()
        harness.keychain.next = .success(expired)
        let store = harness.makeStore()
        await store.refresh(trigger: .poll)

        harness.keychain.next = .success(fresh)
        harness.refresher.exitLast()
        await harness.scheduler.runPending()

        #expect(harness.fetcher.tokens == ["new"])
        #expect(store.auth == .ok)
        #expect(store.failure == nil)
    }

    @Test("a success while the refresh still runs ends the outage; its later exit fetches nothing")
    func successDuringRefresh() async {
        let harness = StoreHarness()
        harness.keychain.next = .success(expired)
        let store = harness.makeStore()
        await store.refresh(trigger: .poll)

        // Another Claude Code process refreshed the token meanwhile.
        harness.keychain.next = .success(fresh)
        await store.refresh(trigger: .manual)
        harness.refresher.exitLast()
        await harness.scheduler.runPending()

        #expect(harness.fetcher.tokens == ["new"])
        #expect(store.auth == .ok)
        #expect(harness.scheduler.pendingDelays.isEmpty)
    }

    @Test("a failed direct launch falls back to the login shell 30 s later, still without a notification")
    func directFailureFallsBack() async {
        let harness = StoreHarness()
        harness.keychain.next = .success(expired)
        let store = harness.makeStore()
        await store.refresh(trigger: .poll)

        harness.refresher.exitLast()
        await harness.scheduler.runPending()

        #expect(store.auth == .waiting(failedAttempts: 1, until: harness.clock.now.addingTimeInterval(30)))
        #expect(store.failure == .refreshingSignIn)
        #expect(harness.notifier.lost == 0)

        harness.clock.advance(30)
        await harness.scheduler.runPending()

        #expect(harness.refresher.starts.map(\.strategy) == [.direct(URL(fileURLWithPath: "/fake/bin/claude")), .loginShell("/bin/zsh")])
    }

    @Test("when the login shell fails too, the user is told once and attempts back off")
    func loginShellFailureNotifiesAndBacksOff() async {
        let harness = StoreHarness()
        harness.keychain.next = .success(expired)
        let store = harness.makeStore()
        await store.refresh(trigger: .poll)
        harness.refresher.exitLast()
        await harness.scheduler.runPending()
        harness.clock.advance(30)
        await harness.scheduler.runPending()

        harness.refresher.exitLast()
        await harness.scheduler.runPending()

        let nextAttempt = harness.clock.now.addingTimeInterval(300)
        #expect(store.failure == .signInExpired(nextAttempt: nextAttempt))
        #expect(harness.notifier.lost == 1)
        #expect(harness.scheduler.pendingDelays == [.seconds(300)])

        // Polls during the wait don't launch anything.
        harness.clock.advance(120)
        await store.refresh(trigger: .poll)
        #expect(harness.refresher.starts.count == 2)
    }

    @Test("a missing claude CLI is reported, notified and retried hourly")
    func cliNotFound() async {
        let harness = StoreHarness()
        harness.refresher.claudeInstalled = false
        harness.keychain.next = .success(expired)
        let store = harness.makeStore()
        await store.refresh(trigger: .poll)

        harness.refresher.exitLast(status: 127)

        #expect(store.failure == .claudeNotFound)
        #expect(harness.notifier.lost == 1)
        #expect(harness.scheduler.pendingDelays == [.seconds(3600)])
    }

    @Test("a manual retry skips the backoff and starts a fresh outage")
    func manualRetrySkipsBackoff() async {
        let harness = StoreHarness()
        harness.keychain.next = .success(expired)
        let store = harness.makeStore()
        await store.refresh(trigger: .poll)
        harness.refresher.exitLast()
        await harness.scheduler.runPending()

        await store.retryManually()

        #expect(harness.refresher.starts.map(\.attempt) == [1, 1])
    }

    @Test("a rejected token that isn't rotated starts the refresh too")
    func rejectedTokenStartsRefresh() async {
        let harness = StoreHarness()
        let store = harness.makeStore()
        await store.refresh(trigger: .poll)

        harness.fetcher.responses = [.failure(.unauthorized)]
        await store.refresh(trigger: .poll)

        #expect(harness.refresher.starts.map(\.attempt) == [1])
        #expect(store.failure == .refreshingSignIn)
        #expect(store.snapshot != nil)
    }
}

@Suite("RefreshPolicy")
struct RefreshPolicyTests {

    private let direct = RefreshStrategy.direct(URL(fileURLWithPath: "/fake/bin/claude"))
    private let shell = RefreshStrategy.loginShell("/bin/zsh")

    @Test("a failed direct launch retries quickly and quietly")
    func directFailure() {
        #expect(RefreshPolicy.afterFailure(attempt: 1, strategy: direct) == .init(retryIn: 30, notify: false))
    }

    @Test("failed login-shell launches notify and back off to an hour", arguments: [
        (1, 300.0), (2, 300.0), (3, 900.0), (4, 3600.0), (9, 3600.0),
    ])
    func loginShellFailures(attempt: Int, delay: TimeInterval) {
        #expect(RefreshPolicy.afterFailure(attempt: attempt, strategy: shell) == .init(retryIn: delay, notify: true))
    }
}
