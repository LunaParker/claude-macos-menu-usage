//
//  KeychainCredentials.swift
//  Menu Bar Usage for Claude
//
//  Reads the OAuth credentials that the `claude` CLI stores in the user's
//  login keychain under the service name "Claude Code-credentials".
//

import Foundation
import Security

/// The decoded OAuth blob written by Claude Code. The refresh token is left
/// undecoded on purpose: the app never uses it, so it never holds it.
nonisolated struct ClaudeCredentials: Decodable, Sendable {
    let accessToken: String
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
}

nonisolated private struct CredentialsEnvelope: Decodable {
    let claudeAiOauth: ClaudeCredentials
}

/// The plaintext file also holds MCP servers' OAuth tokens, so it can exist
/// without a Claude login in it.
nonisolated private struct CredentialsFileEnvelope: Decodable {
    let claudeAiOauth: ClaudeCredentials?
}

nonisolated enum KeychainError: LocalizedError {
    /// The generic-password item is missing entirely — Claude Code was never
    /// authenticated on this machine (or the credential was wiped).
    case itemNotFound
    /// The item existed but the user denied the Keychain access prompt, or
    /// the app isn't permitted to read it.
    case accessDenied(OSStatus)
    /// The underlying Security call returned an unexpected status.
    case unexpectedStatus(OSStatus)
    /// The Keychain item or credentials file didn't match the expected JSON shape.
    case malformedPayload(Error?)

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "Couldn’t find Claude Code credentials in your Keychain or ~/.claude/.credentials.json."
        case .accessDenied(let status):
            return "Keychain access was denied (OSStatus \(status))."
        case .unexpectedStatus(let status):
            return "Unexpected Keychain error (OSStatus \(status))."
        case .malformedPayload:
            return "Claude Code’s stored credentials exist but couldn’t be decoded."
        }
    }
}

/// Which code path read the credentials.
nonisolated enum KeychainReadMethod: Sendable {
    case securityCLI
    case secItemCopyMatching
    /// Claude Code's plaintext fallback, `~/.claude/.credentials.json`.
    case credentialsFile
}

/// Credentials and the path that read them.
nonisolated struct LoadedCredentials: Sendable {
    let credentials: ClaudeCredentials
    let method: KeychainReadMethod
}

/// Where `UsageStore` gets credentials from.
nonisolated protocol CredentialSource: Sendable {
    func load() async throws -> LoadedCredentials
}

/// Reads credentials on a background queue: a read can launch `security`
/// twice and fall back to a Keychain dialog, none of which may block the UI.
nonisolated struct KeychainCredentialSource: CredentialSource {
    private let loader: @Sendable () throws -> LoadedCredentials

    init(loader: @escaping @Sendable () throws -> LoadedCredentials = KeychainCredentialStore.load) {
        self.loader = loader
    }

    func load() async throws -> LoadedCredentials {
        let loader = self.loader
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try loader() })
            }
        }
    }
}

/// Blocking credential reads. Call through `KeychainCredentialSource`.
nonisolated enum KeychainCredentialStore {
    /// The service name the `claude` CLI writes to.
    private static let service = "Claude Code-credentials"

    /// `security` normally answers in milliseconds; a locked keychain can make it wait on a dialog.
    private static let securityTimeout: TimeInterval = 5

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
    /// falls back to no account filter (the initial-login entry). With no
    /// Keychain item at all, reads Claude Code's plaintext file instead.
    static func load() throws -> LoadedCredentials {
        // Primary: /usr/bin/security (silent, no Keychain prompt).
        // Pass 1: account-specific (post-refresh credential).
        if let creds = try? loadViaSecurityCLI(account: NSUserName()) {
            DiagnosticLog.shared.log(.keychain, "Keychain read succeeded via security CLI (account: \(NSUserName()))")
            return LoadedCredentials(credentials: logExpiry(creds), method: .securityCLI)
        }
        // Pass 2: no account filter (initial-login credential).
        if let creds = try? loadViaSecurityCLI(account: nil) {
            DiagnosticLog.shared.log(.keychain, "Keychain read succeeded via security CLI (no account filter)")
            return LoadedCredentials(credentials: logExpiry(creds), method: .securityCLI)
        }

        // Fallback: SecItemCopyMatching. This may trigger a macOS
        // Keychain access prompt, but ensures the app still works if
        // Claude Code changes how it writes credentials or if
        // /usr/bin/security is no longer on the item's ACL.
        DiagnosticLog.shared.log(.keychain, "security CLI failed, falling back to SecItemCopyMatching")
        do {
            return LoadedCredentials(credentials: try loadViaSecItemCopyMatching(), method: .secItemCopyMatching)
        } catch KeychainError.itemNotFound {
            // Claude Code deletes its Keychain item when a Keychain write
            // fails and keeps the credentials in this file instead.
            let creds: ClaudeCredentials
            do {
                creds = try loadFromCredentialsFile()
            } catch {
                DiagnosticLog.shared.log(.keychain, "No usable credentials in ~/.claude/.credentials.json either")
                throw error
            }
            DiagnosticLog.shared.log(.keychain, "Read succeeded via ~/.claude/.credentials.json (Claude Code's plaintext fallback)")
            return LoadedCredentials(credentials: logExpiry(creds), method: .credentialsFile)
        }
    }

    /// Logs the token's expiry status and returns it unchanged.
    private static func logExpiry(_ creds: ClaudeCredentials) -> ClaudeCredentials {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let relative = creds.isExpired
            ? "expired \(formatter.localizedString(for: creds.expirationDate, relativeTo: Date()))"
            : "expires \(formatter.localizedString(for: creds.expirationDate, relativeTo: Date()))"
        DiagnosticLog.shared.log(.keychain, "Token \(relative)")
        return creds
    }

    /// Fallback: reads the credential directly via the Security framework.
    /// May trigger a macOS Keychain access prompt if the app isn't on the
    /// item's ACL (which Claude Code resets on every token refresh).
    private static func loadViaSecItemCopyMatching() throws -> ClaudeCredentials {
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
            DiagnosticLog.shared.log(.keychain, "SecItemCopyMatching succeeded")
        case errSecItemNotFound:
            DiagnosticLog.shared.log(.keychain, "SecItemCopyMatching: item not found")
            throw KeychainError.itemNotFound
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            DiagnosticLog.shared.log(.keychain, "SecItemCopyMatching: access denied (OSStatus \(status))")
            throw KeychainError.accessDenied(status)
        default:
            DiagnosticLog.shared.log(.keychain, "SecItemCopyMatching: unexpected status \(status)")
            throw KeychainError.unexpectedStatus(status)
        }

        guard let data = item as? Data else {
            DiagnosticLog.shared.log(.keychain, "SecItemCopyMatching: data is not Data")
            throw KeychainError.malformedPayload(nil)
        }

        do {
            let envelope = try JSONDecoder().decode(CredentialsEnvelope.self, from: data)
            return logExpiry(envelope.claudeAiOauth)
        } catch {
            DiagnosticLog.shared.log(.keychain, "SecItemCopyMatching: failed to decode payload")
            throw KeychainError.malformedPayload(error)
        }
    }

    /// Where Claude Code stores its credentials when it can't write them to
    /// the Keychain.
    static let credentialsFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/.credentials.json")

    /// Decodes Claude Code's plaintext credential file. A missing file, or one
    /// without a Claude login in it, throws `itemNotFound`.
    static func loadFromCredentialsFile(at url: URL = credentialsFileURL) throws -> ClaudeCredentials {
        guard let data = try? Data(contentsOf: url) else {
            throw KeychainError.itemNotFound
        }
        let envelope: CredentialsFileEnvelope
        do {
            envelope = try JSONDecoder().decode(CredentialsFileEnvelope.self, from: data)
        } catch {
            throw KeychainError.malformedPayload(error)
        }
        guard let credentials = envelope.claudeAiOauth else {
            throw KeychainError.itemNotFound
        }
        return credentials
    }

    /// Runs `/usr/bin/security find-generic-password` and decodes the
    /// resulting JSON. Returns the decoded credentials on success;
    /// throws a `KeychainError` on any failure.
    private static func loadViaSecurityCLI(account: String?) throws -> ClaudeCredentials {
        var args = ["find-generic-password", "-s", service]
        if let account {
            args += ["-a", account]
        }
        args.append("-w")

        let pass = account.map { "account: \($0)" } ?? "no account filter"
        let result: ProcessRunner.Result
        do {
            result = try ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/security"), arguments: args, timeout: securityTimeout)
        } catch {
            DiagnosticLog.shared.log(.keychain, "security CLI (\(pass)) failed to launch: \(error.localizedDescription)")
            throw KeychainError.unexpectedStatus(-1)
        }

        if result.timedOut {
            DiagnosticLog.shared.log(.keychain, "security CLI (\(pass)) timed out after \(Int(securityTimeout)) s and was killed")
            throw KeychainError.unexpectedStatus(-1)
        }

        guard result.status == 0 else {
            // The exit code is the OSStatus's low byte: 44 is errSecItemNotFound.
            let reason = String(decoding: result.stderr, as: UTF8.self)
                .replacingOccurrences(of: "security: ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DiagnosticLog.shared.log(.keychain, "security CLI (\(pass)) exited \(result.status): \(reason.isEmpty ? "no error output" : reason)")
            throw KeychainError.itemNotFound
        }

        let data = result.stdout
        guard !data.isEmpty else {
            throw KeychainError.malformedPayload(nil)
        }

        do {
            let envelope = try JSONDecoder().decode(CredentialsEnvelope.self, from: data)
            return envelope.claudeAiOauth
        } catch {
            DiagnosticLog.shared.log(.keychain, "Failed to decode Keychain payload")
            throw KeychainError.malformedPayload(error)
        }
    }
}
