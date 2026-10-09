//
//  ProcessRunner.swift
//  Menu Bar Usage for Claude
//
//  Runs a short-lived helper process to completion on the calling thread,
//  killing it if it outlives its timeout. Never call it on the main thread.
//

import Foundation
import os

nonisolated enum ProcessRunner {
    struct Result: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data
        let timedOut: Bool
    }

    static func run(_ executable: URL, arguments: [String], timeout: TimeInterval) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.withLock { $0 = true }
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        // Drain both pipes before waiting, so a full pipe buffer can't deadlock.
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errors = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        return Result(status: process.terminationStatus, stdout: output, stderr: errors, timedOut: timedOut.withLock { $0 })
    }
}
