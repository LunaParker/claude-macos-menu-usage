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
/// Launches the `claude` CLI as a hidden background process so its
/// startup sequence can use the stored refresh token to obtain a fresh
/// access token — no visible Terminal window required.
enum CredentialRefresher {
    /// Set when a background refresh has been kicked off. Cleared when
    /// credentials are successfully used again (via
    /// `credentialsBecameValid()`), so a *new* expiry cycle triggers
    /// a fresh attempt.
    private(set) static var hasAttemptedReauth = false

    /// The background `claude` process, if one is currently running.
    private static var refreshProcess: Process?

    /// Kills the background process after this interval if it hasn't
    /// exited on its own. Generous enough for a network token refresh
    /// but short enough that a hung process doesn't linger all day.
    private static let processTimeout: TimeInterval = 30

    /// Called by `UsageStore` after a successful API fetch proves the
    /// credentials are valid. Re-arms the reauth trigger and terminates
    /// any lingering background process.
    static func credentialsBecameValid() {
        hasAttemptedReauth = false
        terminateProcess()
    }

    /// Clears the deduplication guard and kills any in-flight background
    /// process so the very next call to ``refreshInBackground()`` will
    /// launch a fresh `claude`. Used by the popover's manual retry path
    /// — when the user explicitly clicks "Try again", they're asking for
    /// a new attempt regardless of whether one already happened this
    /// expiry cycle.
    static func resetAttemptGuard() {
        terminateProcess()
        hasAttemptedReauth = false
    }

    /// Launches `claude` in the background to refresh expired
    /// credentials. Returns `true` if a process was started, `false`
    /// if a refresh attempt is already in flight or the process
    /// couldn't be launched.
    ///
    /// The CLI auto-refreshes the OAuth access token during its
    /// startup sequence using the stored refresh token, then writes
    /// the updated credentials back to the Keychain. stdin is
    /// /dev/null so the process exits once startup completes instead
    /// of blocking on REPL input.
    ///
    /// A timeout kills the process if it hasn't exited within
    /// ``processTimeout`` seconds, and re-arms `hasAttemptedReauth`
    /// so the next poll cycle can try again.
    @discardableResult
    static func refreshInBackground() -> Bool {
        guard !hasAttemptedReauth else { return false }
        hasAttemptedReauth = true

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // Login shell (-l) inherits the user's PATH so `claude` is
        // discoverable regardless of how it was installed (npm global,
        // Homebrew, volta, etc.).
        process.arguments = ["-l", "-c", "command -v claude &>/dev/null && claude"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            refreshProcess = process
            scheduleTimeout(for: process)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Private

    private static func terminateProcess() {
        if let process = refreshProcess, process.isRunning {
            process.terminate()
        }
        refreshProcess = nil
    }

    /// Schedules a delayed kill for the given process. If the process
    /// is still alive after the timeout, it's terminated and
    /// `hasAttemptedReauth` is cleared so the next poll cycle retries.
    private static func scheduleTimeout(for process: Process) {
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + processTimeout
        ) {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.main.async {
                // Only clear if this is still the process we're tracking
                // (a new attempt may have started in the meantime).
                if refreshProcess?.processIdentifier == process.processIdentifier {
                    refreshProcess = nil
                    hasAttemptedReauth = false
                }
            }
        }
    }
}
