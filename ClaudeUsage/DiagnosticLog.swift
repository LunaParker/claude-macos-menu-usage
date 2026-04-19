//
//  DiagnosticLog.swift
//  Menu Bar Usage for Claude
//
//  In-memory diagnostic log for Keychain reads, API requests, and
//  background credential refresh events. Accessible from both SwiftUI
//  views (@MainActor) and static utility enums (background threads).
//

import Foundation
import Observation

@Observable
@MainActor
final class DiagnosticLog {
    /// Shared instance used app-wide. `CredentialRefresher` (a static
    /// enum whose termination handler fires on a background thread)
    /// uses this directly; SwiftUI views receive it through
    /// `@Environment`.
    static let shared = DiagnosticLog()

    struct Entry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let category: Category
        let message: String

        enum Category: String, CaseIterable {
            case keychain = "Keychain"
            case api = "API"
            case refresh = "Refresh"
        }
    }

    private(set) var entries: [Entry] = []

    /// Maximum entries kept in memory. At ~4 entries per 5-minute poll
    /// cycle, 500 entries covers roughly 10 hours of history.
    private let maxEntries = 500

    /// Appends an entry on the main actor.
    func log(_ category: Entry.Category, _ message: String) {
        entries.append(Entry(timestamp: Date(), category: category, message: message))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func clear() {
        entries.removeAll()
    }

    /// Thread-safe trampoline for callers off the main actor (e.g.
    /// `CredentialRefresher`'s process termination handler).
    nonisolated func post(_ category: Entry.Category, _ message: String) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.log(category, message)
            }
        }
    }
}
