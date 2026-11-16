//
//  TokenFingerprintTests.swift
//  ClaudeUsageTests
//
//  The diagnostic log names tokens by a short hash, never the token itself.
//

import Foundation
import Testing
@testable import ClaudeUsage

@Suite("TokenFingerprint")
struct TokenFingerprintTests {

    @Test("is the first 8 hex characters of the token's SHA-256")
    func knownValue() {
        #expect(TokenFingerprint.of("token-1") == "3f08aace")
    }

    @Test("differs between tokens")
    func distinct() {
        #expect(TokenFingerprint.of("token-1") != TokenFingerprint.of("token-2"))
    }

    @Test("never contains the token")
    func doesNotLeak() {
        let token = "sk-ant-oat01-abcdef"
        #expect(!TokenFingerprint.of(token).contains("sk-ant"))
        #expect(TokenFingerprint.of(token).count == 8)
    }
}
