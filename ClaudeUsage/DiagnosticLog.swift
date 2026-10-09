//
//  DiagnosticLog.swift
//  Menu Bar Usage for Claude
//
//  Timestamped log of Keychain reads, API requests and background credential
//  refreshes. Each entry goes to the unified log (subsystem
//  com.shyowlstudios.ClaudeUsage), to ~/Library/Logs/ClaudeUsage/diagnostic.log
//  and to the list the Diagnostic Log window shows.
//

import AppKit
import Foundation
import Observation
import OSLog
import Synchronization

@Observable
@MainActor
final class DiagnosticLog {
    nonisolated static let shared = DiagnosticLog(logFileURL: defaultLogFileURL)

    nonisolated static let subsystem = "com.shyowlstudios.ClaudeUsage"

    nonisolated struct Entry: Identifiable, Sendable {
        let id = UUID()
        let timestamp: Date
        let category: Category
        let message: String

        nonisolated enum Category: String, CaseIterable, Sendable {
            case keychain = "Keychain"
            case api = "API"
            case refresh = "Refresh"
            case status = "Status"
        }
    }

    /// The most recent entries, oldest first.
    private(set) var entries: [Entry] = []

    private let maxEntries = 500

    @ObservationIgnored nonisolated let logFileURL: URL
    @ObservationIgnored private nonisolated let sink: LogSink

    nonisolated private static let loggers = Dictionary(uniqueKeysWithValues: Entry.Category.allCases.map {
        ($0, Logger(subsystem: subsystem, category: $0.rawValue))
    })

    /// A unit-test host logs to a scratch file so test runs never touch the real log.
    nonisolated private static var defaultLogFileURL: URL {
        if LaunchContext.isUnitTestHost {
            return FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeUsageTests-diagnostic.log")
        }
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/ClaudeUsage/diagnostic.log")
    }

    nonisolated init(logFileURL: URL) {
        self.logFileURL = logFileURL
        sink = LogSink(fileURL: logFileURL)
    }

    /// Records an entry, stamped now. Safe to call from any thread.
    nonisolated func log(_ category: Entry.Category, _ message: String) {
        let entry = Entry(timestamp: Date(), category: category, message: message)
        Self.loggers[category]?.log("\(message, privacy: .public)")
        sink.write(entry)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.append(entry) }
        }
    }

    /// Entries logged on other threads can arrive out of order, so insert by time.
    func append(_ entry: Entry) {
        let index = entries.lastIndex { $0.timestamp <= entry.timestamp }.map { $0 + 1 } ?? 0
        entries.insert(entry, at: index)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    /// Empties the window's list. The log file keeps every entry.
    func clear() {
        entries.removeAll()
    }

    func revealInFinder() {
        NSWorkspace.shared.selectFile(logFileURL.path, inFileViewerRootedAtPath: "")
    }
}

/// Appends entries to the log file, trimming it to its most recent lines
/// whenever it passes `maxFileSize`.
nonisolated final class LogSink: Sendable {
    private struct State {
        var handle: FileHandle?
    }

    private let fileURL: URL
    private let maxFileSize: UInt64
    private let trimTarget: Int
    private let state: Mutex<State>

    init(fileURL: URL, maxFileSize: UInt64 = 512 * 1024, trimTarget: Int = 256 * 1024) {
        self.fileURL = fileURL
        self.maxFileSize = maxFileSize
        self.trimTarget = trimTarget
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? UInt64, size > maxFileSize {
            Self.trim(fileURL, keeping: trimTarget)
        }
        state = Mutex(State(handle: Self.openForAppending(fileURL)))
    }

    static func line(for entry: DiagnosticLog.Entry, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return "\(formatter.string(from: entry.timestamp)) [\(entry.category.rawValue)] \(entry.message)\n"
    }

    func write(_ entry: DiagnosticLog.Entry) {
        let data = Data(Self.line(for: entry).utf8)
        state.withLock { state in
            try? state.handle?.write(contentsOf: data)
            guard let size = try? state.handle?.offset(), size > maxFileSize else { return }
            try? state.handle?.close()
            Self.trim(fileURL, keeping: trimTarget)
            state.handle = Self.openForAppending(fileURL)
        }
    }

    private static func openForAppending(_ url: URL) -> FileHandle? {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }

    /// Keeps the last `target` bytes, starting at a line boundary.
    private static func trim(_ url: URL, keeping target: Int) {
        guard let data = try? Data(contentsOf: url), data.count > target else { return }
        var kept = data[(data.count - target)...]
        if let newline = kept.firstIndex(of: UInt8(ascii: "\n")) {
            kept = kept[(newline + 1)...]
        }
        try? Data(kept).write(to: url)
    }
}
