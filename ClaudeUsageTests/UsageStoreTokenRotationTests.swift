//
//  UsageStoreTokenRotationTests.swift
//  ClaudeUsageTests
//
//  Claude Code replaces its access token five minutes before it expires and
//  the old one stops working at once. A request sent with the old token can
//  draw a 429 with an hour's Retry-After, so the store re-reads the Keychain
//  near expiry and retries a 429 once when a newer token is waiting.
//

import Foundation
import Testing
@testable import ClaudeUsage

@Suite("UsageStore token rotation")
struct UsageStoreTokenRotationTests {

    @Test("a cached token with under 10 minutes left is re-read from the Keychain")
    func nearExpiryRereads() async {
        let harness = StoreHarness()
        harness.keychain.next = .success(TestCredentials.valid(token: "token-1", expiresIn: 8 * 60))
        let store = harness.makeStore()
        await store.refresh()

        harness.keychain.next = .success(TestCredentials.valid(token: "token-2", expiresIn: 8 * 3600))
        await store.refresh()

        #expect(harness.keychain.loads == 2)
        #expect(harness.fetcher.tokens == ["token-1", "token-2"])
    }

    @Test("a near-expiry re-read that finds the same token still uses it")
    func nearExpirySameToken() async {
        let harness = StoreHarness()
        harness.keychain.next = .success(TestCredentials.valid(token: "token-1", expiresIn: 8 * 60))
        let store = harness.makeStore()
        await store.refresh()

        await store.refresh()

        #expect(harness.fetcher.tokens == ["token-1", "token-1"])
        #expect(store.failure == nil)
    }

    @Test("a cached token with more than 10 minutes left is reused")
    func farFromExpiryCached() async {
        let harness = StoreHarness()
        harness.keychain.next = .success(TestCredentials.valid(token: "token-1", expiresIn: 11 * 60))
        let store = harness.makeStore()
        await store.refresh()

        await store.refresh()

        #expect(harness.keychain.loads == 1)
    }

    @Test("a 429 is retried once with a newer token from the Keychain")
    func rateLimitedRetriesWithNewToken() async {
        let harness = StoreHarness()
        let store = harness.makeStore()
        await store.refresh()

        harness.fetcher.responses = [.failure(.rateLimited(retryAfter: 3600)), .success(.sample(session: 60))]
        harness.keychain.next = .success(TestCredentials.valid(token: "token-2"))
        await store.refresh()

        #expect(harness.fetcher.tokens == ["token-1", "token-1", "token-2"])
        #expect(store.rateLimitedUntil == nil)
        #expect(store.failure == nil)
        #expect(store.snapshot?.session?.fraction == 0.6)
    }

    @Test("a 429 with the same token in the Keychain starts the cooldown after one request")
    func rateLimitedSameToken() async {
        let harness = StoreHarness()
        let store = harness.makeStore()
        await store.refresh()

        harness.fetcher.responses = [.failure(.rateLimited(retryAfter: 3600))]
        await store.refresh()

        #expect(harness.fetcher.tokens == ["token-1", "token-1"])
        #expect(store.rateLimitedUntil == harness.clock.now.addingTimeInterval(3600))
    }

    @Test("a retry that is also rate limited starts the cooldown from its own Retry-After")
    func retryAlsoRateLimited() async {
        let harness = StoreHarness()
        let store = harness.makeStore()
        await store.refresh()

        harness.fetcher.responses = [.failure(.rateLimited(retryAfter: 3600)), .failure(.rateLimited(retryAfter: 1800))]
        harness.keychain.next = .success(TestCredentials.valid(token: "token-2"))
        await store.refresh()

        #expect(harness.fetcher.tokens == ["token-1", "token-1", "token-2"])
        let until = harness.clock.now.addingTimeInterval(1800)
        #expect(store.rateLimitedUntil == until)
        #expect(store.failure == .rateLimited(until: until))
    }

    @Test("a 429 whose Keychain re-read fails starts the cooldown")
    func rateLimitedRereadFails() async {
        let harness = StoreHarness()
        let store = harness.makeStore()
        await store.refresh()

        harness.fetcher.responses = [.failure(.rateLimited(retryAfter: 3600))]
        harness.keychain.next = .failure(.itemNotFound)
        await store.refresh()

        #expect(harness.fetcher.tokens == ["token-1", "token-1"])
        #expect(store.rateLimitedUntil == harness.clock.now.addingTimeInterval(3600))
    }
}
