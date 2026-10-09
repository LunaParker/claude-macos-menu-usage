//
//  ClaudeCLITests.swift
//  ClaudeUsageTests
//
//  The background refresh runs `claude mcp list` so Claude Code refreshes
//  its own token. These tests run the real launch paths against fake
//  `claude` scripts in temporary folders, with HOME pointed at an empty
//  folder so no real shell profile or CLI is involved.
//

import Foundation
import Testing
@testable import ClaudeUsage

@Suite("ClaudeCLILocator")
struct ClaudeCLILocatorTests {

    private let cached = URL(fileURLWithPath: "/cached/claude")
    private let native = URL(fileURLWithPath: "/home/.local/bin/claude")
    private let homebrew = URL(fileURLWithPath: "/opt/homebrew/bin/claude")

    @Test("a cached path that still exists wins")
    func cachedPathWins() {
        let locator = ClaudeCLILocator(knownLocations: [native, homebrew]) { _ in true }

        #expect(locator.locate(cached: cached) == cached)
    }

    @Test("a stale cached path falls back to the first known location that exists")
    func fallsBackToKnownLocations() {
        let locator = ClaudeCLILocator(knownLocations: [native, homebrew]) { $0 == homebrew }

        #expect(locator.locate(cached: cached) == homebrew)
    }

    @Test("nothing installed in a known location means no direct path")
    func nothingFound() {
        let locator = ClaudeCLILocator(knownLocations: [native, homebrew]) { _ in false }

        #expect(locator.locate(cached: cached) == nil)
    }

    @Test("only an absolute path from `command -v` counts", arguments: [
        ("/Users/someone/.local/bin/claude\n", "/Users/someone/.local/bin/claude"),
        ("Welcome back!\n/Users/someone/.local/bin/claude\n", "/Users/someone/.local/bin/claude"),
        ("alias claude='npx claude'\n", nil),
        ("claude\n", nil),
        ("", nil),
    ] as [(String, String?)])
    func parsesCommandV(output: String, expected: String?) {
        #expect(ClaudeCLILocator.parseCommandV(output)?.path == expected)
    }
}

@Suite("RefreshStrategy")
struct RefreshStrategyTests {

    private let claude = URL(fileURLWithPath: "/home/.local/bin/claude")

    @Test("the first attempt launches claude directly; later ones go through the login shell")
    func strategyPerAttempt() {
        #expect(RefreshStrategy.choose(attempt: 1, claude: claude, loginShell: "/bin/zsh") == .direct(claude))
        #expect(RefreshStrategy.choose(attempt: 2, claude: claude, loginShell: "/bin/zsh") == .loginShell("/bin/zsh"))
    }

    @Test("without a known path every attempt uses the login shell")
    func loginShellWithoutPath() {
        #expect(RefreshStrategy.choose(attempt: 1, claude: nil, loginShell: "/bin/zsh") == .loginShell("/bin/zsh"))
    }

    @Test("the login-shell command exits 127 when the CLI isn't on PATH", arguments: ["/bin/zsh", "/bin/bash"])
    func loginShellReportsMissingCLI(shell: String) throws {
        let sandbox = try FakeCLI.sandbox()
        let command = RefreshStrategy.loginShell(shell).command(binary: "claude-missing-\(UUID().uuidString.prefix(8))")

        let status = try runToCompletion(command, environment: sandbox.environment)

        #expect(status == 127)
    }

    @Test("the login-shell command runs `mcp list` on the CLI it finds", arguments: ["/bin/zsh", "/bin/bash"])
    func loginShellRunsMCPList(shell: String) throws {
        let sandbox = try FakeCLI.sandbox()
        let fake = try FakeCLI.make(in: sandbox)
        let command = RefreshStrategy.loginShell(shell).command(binary: fake.name)

        let status = try runToCompletion(command, environment: sandbox.environment)

        #expect(status == 0)
        #expect(try fake.recordedArguments() == "mcp list")
    }

    /// Runs a command with an explicit environment, as the login shell would see it.
    private func runToCompletion(_ command: RefreshCommand, environment: [String: String]) throws -> Int32 {
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

@Suite("ClaudeCLIRefresher")
struct ClaudeCLIRefresherTests {

    @Test("a direct launch runs `mcp list` in the private folder with the CLI's folder on PATH")
    func directLaunch() async throws {
        let sandbox = try FakeCLI.sandbox()
        let fake = try FakeCLI.make(in: sandbox)
        let refresher = ClaudeCLIRefresher()

        let exit = try await launchAndWait(refresher, RefreshStrategy.direct(fake.url).command())

        #expect(exit.status == 0)
        #expect(try fake.recordedArguments() == "mcp list")
        let directory = URL(fileURLWithPath: try fake.recordedDirectory()).resolvingSymlinksInPath()
        #expect(directory.path == RefreshWorkingDirectory.url.resolvingSymlinksInPath().path)
        #expect(try fake.recordedPATH().hasPrefix(fake.url.deletingLastPathComponent().path + ":"))
    }

    @Test("a refresh that hangs is killed after the timeout", .timeLimit(.minutes(1)))
    func killsHungRefresh() async throws {
        let sandbox = try FakeCLI.sandbox()
        let fake = try FakeCLI.make(in: sandbox, body: "sleep 60")
        let refresher = ClaudeCLIRefresher(timeout: .milliseconds(500))

        let exit = try await launchAndWait(refresher, RefreshStrategy.direct(fake.url).command())

        #expect(exit.wasKilled)
    }

    private func launchAndWait(_ refresher: ClaudeCLIRefresher, _ command: RefreshCommand) async throws -> ClaudeCLIRefresher.Exit {
        try await withCheckedThrowingContinuation { continuation in
            do {
                _ = try refresher.launch(command) { continuation.resume(returning: $0) }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// A fake `claude` that records its arguments, working directory and PATH.
private struct FakeCLI {
    struct Sandbox {
        let root: URL
        var environment: [String: String] {
            ["HOME": root.path, "PATH": "\(root.path)/bin:/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "dumb"]
        }
    }

    let url: URL
    let output: URL
    var name: String { url.lastPathComponent }

    static func sandbox() throws -> Sandbox {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FakeCLI-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        // Empty profiles keep the user's real shell configuration out of the run.
        for profile in [".zshrc", ".zprofile", ".zshenv", ".bashrc", ".bash_profile"] {
            FileManager.default.createFile(atPath: root.appendingPathComponent(profile).path, contents: Data())
        }
        return Sandbox(root: root)
    }

    static func make(in sandbox: Sandbox, body: String = "") throws -> FakeCLI {
        let name = "claude-fake-\(UUID().uuidString.prefix(8))"
        let url = sandbox.root.appendingPathComponent("bin/\(name)")
        let output = sandbox.root.appendingPathComponent("\(name).out")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" > '\(output.path)'
        pwd -P >> '\(output.path)'
        printf '%s\\n' "$PATH" >> '\(output.path)'
        \(body)
        """
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return FakeCLI(url: url, output: output)
    }

    private func lines() throws -> [String] {
        try String(contentsOf: output, encoding: .utf8).components(separatedBy: "\n")
    }

    func recordedArguments() throws -> String { try lines()[0] }
    func recordedDirectory() throws -> String { try lines()[1] }
    func recordedPATH() throws -> String { try lines()[2] }
}
