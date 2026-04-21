//
//  KeychainCredentials.swift
//  Menu Bar Usage for Claude
//
//  Reads the OAuth credentials that the `claude` CLI stores in the user's
//  login keychain under the service name "Claude Code-credentials".
//

import Foundation

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

    /// Reads and decodes the Claude Code OAuth credentials from the login
    /// keychain using `/usr/bin/security`.
    ///
    /// `/usr/bin/security` is already on the ACL that Claude Code creates
    /// when writing the credential, so reads succeed silently without
    /// triggering a macOS Keychain access prompt — unlike
    /// `SecItemCopyMatching`, which presents a dialog every time the ACL
    /// is reset (i.e. after every token refresh by Claude Code).
    ///
    /// Two-pass lookup: tries the current macOS username first (the
    /// account field Claude Code writes after a token refresh), then
    /// falls back to no account filter (the initial-login entry).
    static func load() throws -> ClaudeCredentials {
        // Pass 1: account-specific (post-refresh credential).
        if let creds = try? loadViaSecurityCLI(account: NSUserName()) {
            DiagnosticLog.shared.post(.keychain, "Keychain read succeeded (account: \(NSUserName()))")
            return logExpiry(creds)
        }
        // Pass 2: no account filter (initial-login credential).
        do {
            let creds = try loadViaSecurityCLI(account: nil)
            DiagnosticLog.shared.post(.keychain, "Keychain read succeeded (no account filter)")
            return logExpiry(creds)
        } catch {
            DiagnosticLog.shared.post(.keychain, "Keychain read failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Logs the token's expiry status and returns it unchanged.
    private static func logExpiry(_ creds: ClaudeCredentials) -> ClaudeCredentials {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let relative = creds.isExpired
            ? "expired \(formatter.localizedString(for: creds.expirationDate, relativeTo: Date()))"
            : "expires \(formatter.localizedString(for: creds.expirationDate, relativeTo: Date()))"
        DiagnosticLog.shared.post(.keychain, "Token \(relative)")
        return creds
    }

    /// Runs `/usr/bin/security find-generic-password` and decodes the
    /// resulting JSON. Returns the decoded credentials on success;
    /// throws a `KeychainError` on any failure.
    private static func loadViaSecurityCLI(account: String?) throws -> ClaudeCredentials {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        var args = ["find-generic-password", "-s", service]
        if let account {
            args += ["-a", account]
        }
        args.append("-w")
        process.arguments = args

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw KeychainError.unexpectedStatus(-1)
        }

        // Drain the pipe before waiting so a large payload can't
        // deadlock against a full pipe buffer (ours is tiny, but
        // this is the safe ordering).
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw KeychainError.itemNotFound
        }

        guard !data.isEmpty else {
            throw KeychainError.malformedPayload(nil)
        }

        do {
            let envelope = try JSONDecoder().decode(CredentialsEnvelope.self, from: data)
            return envelope.claudeAiOauth
        } catch {
            DiagnosticLog.shared.post(.keychain, "Failed to decode Keychain payload")
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

    /// Called on the main thread when the background refresh process
    /// exits (normally or via timeout). Set by `UsageStore` at startup
    /// so the store can clear its observable `isRefreshingCredentials`.
    static var onRefreshEnded: (() -> Void)?

    /// Kills the background process after this interval if it hasn't
    /// exited on its own. Generous enough for a network token refresh
    /// but short enough that a hung process doesn't linger all day.
    private static let processTimeout: TimeInterval = 30

    /// Called by `UsageStore` after a successful API fetch proves the
    /// credentials are valid. Re-arms the reauth trigger and terminates
    /// any lingering background process.
    static func credentialsBecameValid() {
        DiagnosticLog.shared.post(.refresh, "Credentials validated, clearing refresh state")
        hasAttemptedReauth = false
        terminateProcess()
        onRefreshEnded?()
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
        guard !hasAttemptedReauth else {
            DiagnosticLog.shared.post(.refresh, "Skipped: refresh already attempted")
            return false
        }
        hasAttemptedReauth = true

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // Login shell (-l) inherits the user's PATH so `claude` is
        // discoverable regardless of how it was installed (npm global,
        // Homebrew, volta, etc.).
        process.arguments = ["-l", "-c", "command -v claude &>/dev/null && claude"]
        // Pin to /tmp so the child process (and the `claude` CLI's
        // project-context resolution) never touches TCC-protected user
        // directories like ~/Desktop, ~/Documents, or ~/Downloads.
        process.currentDirectoryURL = URL(fileURLWithPath: "/tmp")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        // When the process exits (normally or killed), clear the
        // dedup guard so the next poll cycle can retry with fresh
        // credentials. Without this, a fast-exiting `claude` would
        // leave hasAttemptedReauth stuck at `true` indefinitely.
        process.terminationHandler = { terminatedProcess in
            let code = terminatedProcess.terminationStatus
            DiagnosticLog.shared.post(.refresh, "Process exited with code \(code)")
            DispatchQueue.main.async {
                if refreshProcess?.processIdentifier == terminatedProcess.processIdentifier {
                    refreshProcess = nil
                    hasAttemptedReauth = false
                    onRefreshEnded?()
                }
            }
        }

        do {
            try process.run()
            refreshProcess = process
            DiagnosticLog.shared.post(.refresh, "Background claude process launched (PID \(process.processIdentifier))")
            scheduleTimeout(for: process)
            return true
        } catch {
            DiagnosticLog.shared.post(.refresh, "Failed to launch claude process: \(error)")
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
            DiagnosticLog.shared.post(.refresh, "Process timed out after \(processTimeout)s, terminating")
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
