//
//  UsageState.swift
//  Menu Bar Usage for Claude
//
//  What can go wrong when fetching usage, and how the popover and menu bar
//  present the store's state.
//

import Foundation

/// Why the latest refresh didn't produce fresh usage.
enum UsageFailure: Equatable, Sendable {
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
