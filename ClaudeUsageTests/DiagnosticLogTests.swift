//
//  DiagnosticLogTests.swift
//  ClaudeUsageTests
//
//  The diagnostic log is the main forensic tool for this app, so its
//  timestamps and ordering have to be trustworthy, its file has to stay
//  bounded while the app runs, and its entries have to be readable in the
//  unified log next to the system's own (`security`, sleep and wake).
//

import Foundation
import OSLog
import Testing
@testable import ClaudeUsage

@Suite("DiagnosticLog")
struct DiagnosticLogTests {

    @Test("an entry is stamped when it is logged, not when the main queue gets to it")
    func stampedAtCallTime() async throws {
        let log = DiagnosticLog(logFileURL: temporaryLogFile())
        let before = Date()

        log.log(.keychain, "probe")
        blockCurrentThread(seconds: 0.3)  // the main queue can't run the append yet
        for _ in 0..<100 where log.entries.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }

        let entry = try #require(log.entries.last)
        #expect(entry.message == "probe")
        #expect(entry.timestamp.timeIntervalSince(before) < 0.2)
    }

    @Test("entries that arrive out of order are listed in time order")
    func keepsTimeOrder() {
        let log = DiagnosticLog(logFileURL: temporaryLogFile())
        let now = Date()

        log.append(.init(timestamp: now, category: .api, message: "second"))
        log.append(.init(timestamp: now.addingTimeInterval(-1), category: .keychain, message: "first"))

        #expect(log.entries.map(\.message) == ["first", "second"])
    }

    @Test("entries reach the unified log with their text readable")
    func mirroredToUnifiedLog() async throws {
        let marker = "probe \(UUID().uuidString)"
        let log = DiagnosticLog(logFileURL: temporaryLogFile())

        log.log(.refresh, marker)

        var found = false
        for _ in 0..<20 where !found {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            found = try store.getEntries(matching: NSPredicate(format: "subsystem == %@", DiagnosticLog.subsystem))
                .contains { ($0 as? OSLogEntryLog)?.composedMessage == marker }
            if !found { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(found)
    }
}

@Suite("LogSink")
struct LogSinkTests {

    @Test("file lines carry millisecond timestamps")
    func lineFormat() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let entry = DiagnosticLog.Entry(
            timestamp: Date(timeIntervalSince1970: 1_791_548_190.125),
            category: .api,
            message: "Request #5 started"
        )

        #expect(LogSink.line(for: entry, timeZone: utc) == "2026-10-09 12:16:30.125 [API] Request #5 started\n")
    }

    @Test("the file is trimmed while the app runs, keeping whole recent lines")
    func trimsWhileRunning() throws {
        let url = temporaryLogFile()
        let sink = LogSink(fileURL: url, maxFileSize: 2_000, trimTarget: 1_000)

        for index in 0..<200 {
            sink.write(.init(timestamp: Date(), category: .api, message: "line \(index)"))
        }

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.utf8.count <= 2_000)
        #expect(text.hasSuffix(" [API] line 199\n"))
        #expect(text.split(separator: "\n").allSatisfy { $0.contains(" [API] line ") })
    }
}

private func blockCurrentThread(seconds: TimeInterval) {
    Thread.sleep(forTimeInterval: seconds)
}

private func temporaryLogFile() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("diagnostic.log")
}
