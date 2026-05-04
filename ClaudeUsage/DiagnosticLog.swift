//
//  DiagnosticLog.swift
//  Menu Bar Usage for Claude
//
//  In-memory diagnostic log for Keychain reads, API requests, and
//  background credential refresh events. Accessible from both SwiftUI
//  views (@MainActor) and static utility enums (background threads).
//
//  Entries are also appended to a persistent log file at
//  ~/Library/Logs/ClaudeUsage/diagnostic.log so they survive across
//  app launches and can be shared for debugging.
//

import AppKit
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
            case status = "Status"
        }
    }

    private(set) var entries: [Entry] = []

    /// Maximum entries kept in memory. At ~4 entries per 5-minute poll
    /// cycle, 500 entries covers roughly 10 hours of history.
    private let maxEntries = 500

    /// URL of the persistent log file.
    let logFileURL: URL

    /// File handle kept open for appending.
    private var fileHandle: FileHandle?

    /// Maximum log file size before truncation on launch.
    private let maxFileSize: Int = 512 * 1024 // 512 KB

    /// Target size after truncation (keeps the most recent entries).
    private let truncateTarget: Int = 256 * 1024 // 256 KB

    private static let fileDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    init() {
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs")
            .appendingPathComponent("ClaudeUsage")
        logFileURL = logsDir.appendingPathComponent("diagnostic.log")

        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        truncateIfNeeded()

        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: logFileURL)
        fileHandle?.seekToEndOfFile()
    }

    /// Appends an entry on the main actor.
    func log(_ category: Entry.Category, _ message: String) {
        let entry = Entry(timestamp: Date(), category: category, message: message)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        writeToFile(entry)
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

    /// Opens the log file's parent folder in Finder with the file selected.
    func revealInFinder() {
        NSWorkspace.shared.selectFile(logFileURL.path, inFileViewerRootedAtPath: "")
    }

    // MARK: - File logging

    private func writeToFile(_ entry: Entry) {
        let timestamp = Self.fileDateFormatter.string(from: entry.timestamp)
        let line = "\(timestamp) [\(entry.category.rawValue)] \(entry.message)\n"
        guard let data = line.data(using: .utf8) else { return }
        fileHandle?.write(data)
    }

    /// If the log file exceeds `maxFileSize`, keep only the last
    /// `truncateTarget` bytes (starting at a line boundary).
    private func truncateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let size = attrs[.size] as? Int,
              size > maxFileSize
        else { return }

        guard let data = try? Data(contentsOf: logFileURL),
              data.count > truncateTarget
        else { return }

        let keepFrom = data.count - truncateTarget
        var kept = data[keepFrom...]

        // Advance to the first newline so we start on a complete line.
        if let nl = kept.firstIndex(of: UInt8(ascii: "\n")) {
            kept = kept[(nl + 1)...]
        }

        try? Data(kept).write(to: logFileURL)
    }
}
