//
//  RotatedCredentialsTests.swift
//  ClaudeUsageTests
//
//  Covers `UsageStore.rotatedCredentials(replacing:reloaded:)`, the
//  decision behind the 401 handling: Claude Code rotates the access token
//  whenever it refreshes, and the previous token is rejected immediately,
//  so a 401 on a *cached* token usually means the Keychain already holds
//  the replacement. Only when the re-read yields nothing usable should the
//  401 be treated as a real authentication loss.
//

import Foundation
import Testing
@testable import ClaudeUsage

@Suite("UsageStore.rotatedCredentials")
struct RotatedCredentialsTests {

    private let rejected = makeCredentials(accessToken: "old-token", expiresInSeconds: 3600)

    @Test("a failed Keychain re-read yields nothing to retry with")
    func reloadFailed() {
        #expect(UsageStore.rotatedCredentials(replacing: rejected, reloaded: nil) == nil)
    }

    @Test("the same token read back means no rotation happened")
    func sameToken() {
        let reloaded = makeCredentials(accessToken: "old-token", expiresInSeconds: 3600)

        #expect(UsageStore.rotatedCredentials(replacing: rejected, reloaded: reloaded) == nil)
    }

    @Test("a different, unexpired token is returned for a silent retry")
    func rotatedToken() {
        let reloaded = makeCredentials(accessToken: "new-token", expiresInSeconds: 3600)

        let result = UsageStore.rotatedCredentials(replacing: rejected, reloaded: reloaded)

        #expect(result?.accessToken == "new-token")
    }

    @Test("a different but expired token is not retried")
    func rotatedButExpired() {
        let reloaded = makeCredentials(accessToken: "new-token", expiresInSeconds: -60)

        #expect(UsageStore.rotatedCredentials(replacing: rejected, reloaded: reloaded) == nil)
    }
}

// MARK: - Helpers

private func makeCredentials(accessToken: String, expiresInSeconds: TimeInterval) -> ClaudeCredentials {
    ClaudeCredentials(
        accessToken: accessToken,
        refreshToken: "refresh",
        expiresAt: Int64((Date().timeIntervalSince1970 + expiresInSeconds) * 1000),
        scopes: [],
        subscriptionType: nil,
        rateLimitTier: nil
    )
}
