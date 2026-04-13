//
//  KeychainCredentials.swift
//  Menu Bar Usage for Claude
//
//  Reads the OAuth credentials that the `claude` CLI stores in the user's
//  login keychain under the service name "Claude Code-credentials".
//

import AppKit
import Foundation
import Security

/// The decoded OAuth blob written by Claude Code.
struct ClaudeCredentials: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String
    /// Milliseconds since the Unix epoch.
    let expiresAt: Int64
    let scopes: [String]
    let subscriptionType: String?
    let rateLimitTier: String?

    var expirationDate: Date {
        Date(timeIntervalSince1970: TimeInterval(expiresAt) / 1000)
    }

    var isExpired: Bool {
        expirationDate <= Date()
    }

    /// True if the account is on any "max" tier (Max 5x / Max 20x).
    /// Used to decide whether the Sonnet-specific bar should appear.
    var isMaxSubscription: Bool {
        (subscriptionType ?? "").lowercased().contains("max")
            || (rateLimitTier ?? "").lowercased().contains("max")
    }
}

private struct CredentialsEnvelope: Decodable {
    let claudeAiOauth: ClaudeCredentials
}

enum KeychainError: LocalizedError {
    /// The generic-password item is missing entirely — Claude Code was never
    /// authenticated on this machine (or the credential was wiped).
    case itemNotFound
    /// The item existed but the user denied the Keychain access prompt, or
    /// the app isn't permitted to read it.
    case accessDenied(OSStatus)
    /// The underlying Security call returned an unexpected status.
    case unexpectedStatus(OSStatus)
    /// The data in the Keychain item didn't match the expected JSON shape.
    case malformedPayload(Error?)

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "Couldn’t find Claude Code credentials in your Keychain."
        case .accessDenied(let status):
            return "Keychain access was denied (OSStatus \(status))."
        case .unexpectedStatus(let status):
            return "Unexpected Keychain error (OSStatus \(status))."
        case .malformedPayload:
            return "The Keychain entry exists but couldn’t be decoded."
        }
    }
}

enum KeychainCredentialStore {
    /// The service name the `claude` CLI writes to.
    private static let service = "Claude Code-credentials"

    /// Reads and decodes the Claude Code OAuth credentials from the login keychain.
    ///
    /// We query with `kSecMatchLimitOne` and no account filter: there's only ever
    /// one Claude Code credential per user, but the account field is the local
    /// username, which we don't want to hard-code.
    static func load() throws -> ClaudeCredentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            throw KeychainError.itemNotFound
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            throw KeychainError.accessDenied(status)
        default:
            throw KeychainError.unexpectedStatus(status)
        }

        guard let data = item as? Data else {
            throw KeychainError.malformedPayload(nil)
        }

        do {
            let envelope = try JSONDecoder().decode(CredentialsEnvelope.self, from: data)
            return envelope.claudeAiOauth
        } catch {
            throw KeychainError.malformedPayload(error)
        }
    }
}

// MARK: - Credential refresh

/// Manages automatic re-authentication when stored credentials expire.
/// Opens Terminal.app with a Claude Code session so the OAuth token
/// refresh (or interactive re-login) can proceed.
///
/// The app has hardened runtime enabled with no Apple Events entitlement,
/// so we can't script Terminal.app directly. Instead we write a temporary
/// `.command` file and open it via `NSWorkspace`, which LaunchServices
/// hands off to Terminal as the default handler.
enum CredentialRefresher {
    /// Set when a terminal window has been opened for reauth. Cleared
    /// when credentials are successfully used again (via
    /// `credentialsBecameValid()`), so a *new* expiry cycle triggers
    /// a fresh terminal window.
    private(set) static var hasAttemptedReauth = false

    /// Called by `UsageStore` after a successful API fetch proves the
    /// credentials are valid. Re-arms the reauth trigger so the next
    /// expiry opens a new terminal.
    static func credentialsBecameValid() {
        hasAttemptedReauth = false
    }

    /// Opens Terminal with a Claude Code session to refresh expired
    /// credentials. Returns `true` if a terminal was opened, `false`
    /// if a reauth attempt is already in flight.
    @discardableResult
    static func openTerminalToRefresh() -> Bool {
        guard !hasAttemptedReauth else { return false }
        hasAttemptedReauth = true

        let script = """
        #!/bin/bash
        # Launched by Menu Bar Usage for Claude to refresh expired credentials.
        echo "Your Claude Code credentials have expired."
        echo "Starting Claude Code to refresh them…"
        echo ""
        if command -v claude &>/dev/null; then
            claude
        else
            echo "'claude' command not found."
            echo ""
            echo "Install Claude Code:"
            echo "  npm install -g @anthropic-ai/claude-code"
            echo ""
            echo "Then authenticate:"
            echo "  claude"
        fi
        rm -f "$0"
        """

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-credential-refresh.command")

        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path
            )
            NSWorkspace.shared.open(url)
            return true
        } catch {
            return false
        }
    }
}
