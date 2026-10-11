//
//  UsageState.swift
//  Menu Bar Usage for Claude
//
//  What can go wrong when fetching usage, and how the popover and menu bar
//  present the store's state.
//

import Foundation

/// Why the latest refresh didn't produce fresh usage.
nonisolated enum UsageFailure: Equatable, Sendable {
    /// No credentials in the Keychain or ~/.claude/.credentials.json.
    case signedOut
    /// The credentials exist but couldn't be read or decoded.
    case credentialsUnreadable(String)
    /// The token expired or was rejected and a background refresh is under way.
    case refreshingSignIn
    /// Background refreshes didn't produce a working token.
    case signInExpired(nextAttempt: Date?)
    /// The refresh couldn't find the `claude` CLI.
    case claudeNotFound
    case rateLimited(until: Date)
    case offline(String)
    case server(status: Int)
    case unexpectedResponse

    /// Failures that only the user can fix. The others keep the last bars on screen.
    var needsUser: Bool {
        switch self {
        case .signedOut, .credentialsUnreadable, .signInExpired, .claudeNotFound:
            true
        case .refreshingSignIn, .rateLimited, .offline, .server, .unexpectedResponse:
            false
        }
    }
}

nonisolated extension UsageFailure {
    var title: String {
        switch self {
        case .signedOut: "Claude Code not authenticated"
        case .credentialsUnreadable: "Couldn’t read your Claude Code credentials"
        case .refreshingSignIn: "Refreshing Claude Code’s sign-in"
        case .signInExpired: "Claude Code needs you to sign in again"
        case .claudeNotFound: "Couldn’t find the claude command"
        case .rateLimited: "Rate-limited by Claude"
        case .offline: "Couldn’t reach Claude"
        case .server(let status): "Claude’s usage endpoint returned HTTP \(status)"
        case .unexpectedResponse: "Couldn’t read Claude’s usage response"
        }
    }

    /// Markdown.
    var detail: String {
        switch self {
        case .signedOut:
            "No credentials in the Keychain or `~/.claude/.credentials.json`."
        case .credentialsUnreadable(let reason):
            reason
        case .refreshingSignIn:
            "The token expired, so Claude Code is refreshing it in the background. This usually takes a few seconds."
        case .signInExpired:
            "The background token refresh didn’t work. Run `claude` in Terminal and type `/login`, then try again."
        case .claudeNotFound:
            "The background token refresh needs Claude Code. Install it, or make sure `claude` is on your login shell’s PATH, then try again."
        case .rateLimited:
            "Claude’s usage endpoint is rate-limiting this app."
        case .offline(let reason):
            reason
        case .server:
            "This is usually temporary. The app will try again shortly."
        case .unexpectedResponse:
            "The endpoint may have changed. The app will keep trying."
        }
    }

    var notice: String {
        switch self {
        case .refreshingSignIn: "Refreshing Claude Code’s sign-in…"
        case .offline: "Couldn’t reach Claude · retrying soon"
        case .server(let status): "Usage endpoint returned HTTP \(status) · retrying soon"
        case .unexpectedResponse: "Couldn’t read the usage response · retrying soon"
        default: title
        }
    }
}

/// Why an App Intent couldn't answer. Shortcuts shows the text.
nonisolated enum UsageRequestError: Error, Equatable {
    case notSetUp
    case unavailable(UsageFailure)
    case noData
}

/// What the popover shows for a snapshot and failure.
enum UsagePresentation: Equatable {
    case loading
    case usage(UsageSnapshot, notice: UsageFailure?)
    case problem(UsageFailure)

    /// Data older than this is too stale for the menu bar, whatever the failure.
    static let menuBarStaleLimit: TimeInterval = 30 * 60

    init(snapshot: UsageSnapshot?, failure: UsageFailure?) {
        if let failure, failure.needsUser || snapshot == nil {
            self = .problem(failure)
        } else if let snapshot {
            self = .usage(snapshot, notice: failure)
        } else {
            self = .loading
        }
    }

    func menuBarSnapshot(now: Date) -> UsageSnapshot? {
        guard case .usage(let snapshot, _) = self,
              now.timeIntervalSince(snapshot.fetchedAt) < Self.menuBarStaleLimit
        else { return nil }
        return snapshot
    }
}

/// Where the background token refresh stands.
enum AuthPhase: Equatable {
    case ok
    /// A refresh process is running.
    case refreshing(attempt: Int, pid: Int32, strategy: RefreshStrategy)
    /// The process exited; the next refresh reads the Keychain to see whether it worked.
    case checking(attempt: Int, strategy: RefreshStrategy)
    /// Attempts haven't produced a working token; the next one starts after `until`.
    case waiting(failedAttempts: Int, until: Date)
}

/// What happens after a refresh attempt fails to produce a working token.
enum RefreshPolicy {
    struct Decision: Equatable {
        let retryIn: TimeInterval
        let notify: Bool
    }

    /// A missing CLI won't fix itself quickly, so it's re-checked hourly.
    static let cliNotFoundRetry: TimeInterval = 3600

    /// A direct launch falls back to the login shell quickly and quietly; the user
    /// hears about it once the login shell has failed too. `nil` means launch failed.
    static func afterFailure(attempt: Int, strategy: RefreshStrategy?) -> Decision {
        if case .direct = strategy {
            return Decision(retryIn: 30, notify: false)
        }
        let delay: TimeInterval = switch attempt {
        case ...2: 300
        case 3: 900
        default: 3600
        }
        return Decision(retryIn: delay, notify: true)
    }
}
