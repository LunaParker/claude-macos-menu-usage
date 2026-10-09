//
//  TestCredentials.swift
//  ClaudeUsageTests
//

import Foundation
@testable import ClaudeUsage

enum TestCredentials {
    static func valid(token: String = "test-token", expiresIn seconds: TimeInterval = 3600) -> ClaudeCredentials {
        ClaudeCredentials(
            accessToken: token,
            refreshToken: "refresh",
            expiresAt: Int64((Date().timeIntervalSince1970 + seconds) * 1000),
            scopes: [],
            subscriptionType: nil,
            rateLimitTier: nil
        )
    }
}
