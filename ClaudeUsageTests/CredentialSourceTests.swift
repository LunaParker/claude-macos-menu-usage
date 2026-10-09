//
//  CredentialSourceTests.swift
//  ClaudeUsageTests
//
//  Reading credentials can launch `security` twice and fall back to a
//  Keychain dialog, so it must never block the main thread, and a hung
//  helper process must be killed rather than waited on forever.
//

import Foundation
import os
import Testing
@testable import ClaudeUsage

@Suite("KeychainCredentialSource")
struct CredentialSourceTests {

    @Test("credentials are read off the main thread")
    func loadsOffMain() async throws {
        let ranOnMain = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let source = KeychainCredentialSource {
            ranOnMain.withLock { $0 = Thread.isMainThread }
            return LoadedCredentials(credentials: TestCredentials.valid(), method: .securityCLI)
        }

        let loaded = try await source.load()

        #expect(ranOnMain.withLock { $0 } == false)
        #expect(loaded.method == .securityCLI)
    }

    @Test("a loader error reaches the caller")
    func propagatesErrors() async {
        let source = KeychainCredentialSource { throw KeychainError.itemNotFound }

        await #expect(throws: KeychainError.self) {
            try await source.load()
        }
    }
}

@Suite("ProcessRunner")
struct ProcessRunnerTests {

    @Test("a process that outlives its timeout is killed", .timeLimit(.minutes(1)))
    func killsHungProcess() throws {
        let started = Date()

        let result = try ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 0.5)

        #expect(result.timedOut)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test("a process that finishes in time returns its status and output")
    func capturesOutput() throws {
        let result = try ProcessRunner.run(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf out; printf err >&2; exit 3"],
            timeout: 5
        )

        #expect(!result.timedOut)
        #expect(result.status == 3)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "out")
        #expect(String(decoding: result.stderr, as: UTF8.self) == "err")
    }
}
