//
//  CredentialsFileTests.swift
//  ClaudeUsageTests
//
//  Covers `KeychainCredentialStore.loadFromCredentialsFile(at:)`, the read of
//  Claude Code's plaintext store. Claude Code switches to it (and deletes the
//  Keychain item) whenever a Keychain write fails.
//

import Foundation
import Testing
@testable import ClaudeUsage

@Suite("KeychainCredentialStore.loadFromCredentialsFile")
struct CredentialsFileTests {

    @Test("reads the Claude OAuth entry and ignores the MCP tokens beside it")
    func readsOAuthEntry() throws {
        let url = try writeCredentialsFile("""
        {
          "mcpOAuth": {"github|0123abcd": {"accessToken": "mcp-token"}},
          "claudeAiOauth": {
            "accessToken": "file-token",
            "refreshToken": "refresh",
            "expiresAt": 1790455700647,
            "refreshTokenExpiresAt": 1798231700647,
            "scopes": ["user:inference"],
            "subscriptionType": "max",
            "rateLimitTier": "default_claude_max_20x"
          }
        }
        """)

        let credentials = try KeychainCredentialStore.loadFromCredentialsFile(at: url)

        #expect(credentials.accessToken == "file-token")
        #expect(credentials.subscriptionType == "max")
    }

    @Test("a missing file reads as not signed in")
    func missingFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(".credentials.json")

        let error = #expect(throws: KeychainError.self) {
            try KeychainCredentialStore.loadFromCredentialsFile(at: url)
        }
        #expect(isItemNotFound(error))
    }

    @Test("a file holding only MCP tokens reads as not signed in")
    func mcpTokensOnly() throws {
        let url = try writeCredentialsFile("""
        {"mcpOAuth": {"github|0123abcd": {"accessToken": "mcp-token"}}}
        """)

        let error = #expect(throws: KeychainError.self) {
            try KeychainCredentialStore.loadFromCredentialsFile(at: url)
        }
        #expect(isItemNotFound(error))
    }

    @Test("unparseable contents are reported as a malformed payload")
    func malformedFile() throws {
        let url = try writeCredentialsFile("not json")

        let error = #expect(throws: KeychainError.self) {
            try KeychainCredentialStore.loadFromCredentialsFile(at: url)
        }
        #expect(isMalformedPayload(error))
    }
}

// MARK: - Helpers

private func writeCredentialsFile(_ contents: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(".credentials.json")
    try Data(contents.utf8).write(to: url)
    return url
}

private func isItemNotFound(_ error: KeychainError?) -> Bool {
    if case .itemNotFound = error { return true }
    return false
}

private func isMalformedPayload(_ error: KeychainError?) -> Bool {
    if case .malformedPayload = error { return true }
    return false
}
