//
//  ClaudeCLI.swift
//  Menu Bar Usage for Claude
//
//  Finds and launches the `claude` CLI in the background so Claude Code
//  refreshes its own expired token and writes the new one to the Keychain.
//

import Foundation

/// Finds the `claude` binary without starting a shell: a cached path, then
/// the places installers put it.
nonisolated struct ClaudeCLILocator: Sendable {
    static let cachedPathKey = "claudeCLIPath"

    static let live: ClaudeCLILocator = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = [
            "\(home)/.local/bin/claude",     // native installer
            "\(home)/.claude/local/claude",  // older local install
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/.volta/bin/claude",
        ]
        return ClaudeCLILocator(knownLocations: paths.map { URL(fileURLWithPath: $0) }) {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }()

    let knownLocations: [URL]
    let isExecutable: @Sendable (URL) -> Bool

    init(knownLocations: [URL], isExecutable: @escaping @Sendable (URL) -> Bool) {
        self.knownLocations = knownLocations
        self.isExecutable = isExecutable
    }

    func locate(cached: URL?) -> URL? {
        if let cached, isExecutable(cached) { return cached }
        return knownLocations.first(where: isExecutable)
    }

    /// Asks the login shell where `claude` is. Blocking; call it off the main thread.
    static func lookUpWithLoginShell(_ shell: String) -> URL? {
        guard let result = try? ProcessRunner.run(URL(fileURLWithPath: shell), arguments: ["-i", "-l", "-c", "command -v claude"], timeout: 15),
              !result.timedOut, result.status == 0
        else { return nil }
        return parseCommandV(String(decoding: result.stdout, as: UTF8.self))
    }

    /// The last line of `command -v` output, if it's an absolute path. An rc file
    /// may print a banner first; an alias or function prints something else.
    static func parseCommandV(_ output: String) -> URL? {
        guard let line = output.split(separator: "\n").last?.trimmingCharacters(in: .whitespaces),
              line.hasPrefix("/")
        else { return nil }
        return URL(fileURLWithPath: line)
    }
}

/// How a refresh attempt starts `claude`.
nonisolated enum RefreshStrategy: Equatable, Sendable {
    /// Run the binary directly, without sourcing any shell profile.
    case direct(URL)
    /// `<shell> -i -l -c …`, so the profile and rc files can put `claude` on PATH.
    case loginShell(String)

    private static let standardPath = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// The direct launch can't be tested against an expired token in advance,
    /// so every attempt after the first uses the proven login-shell launch.
    static func choose(attempt: Int, claude: URL?, loginShell: String) -> RefreshStrategy {
        if attempt == 1, let claude { return .direct(claude) }
        return .loginShell(loginShell)
    }

    /// `mcp list`: bare `claude` needs a TTY, and `claude auth status` only reports
    /// cached state without refreshing. The login shell exits 127 if `claude` is missing.
    func command(binary: String = "claude") -> RefreshCommand {
        switch self {
        case .direct(let url):
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = ([url.deletingLastPathComponent().path] + Self.standardPath).joined(separator: ":")
            return RefreshCommand(executable: url, arguments: ["mcp", "list"], environment: environment)
        case .loginShell(let shell):
            let script = "command -v \(binary) >/dev/null 2>&1 || exit 127; exec \(binary) mcp list"
            return RefreshCommand(executable: URL(fileURLWithPath: shell), arguments: ["-i", "-l", "-c", script], environment: nil)
        }
    }

    var logDescription: String {
        switch self {
        case .direct(let url): "direct: \(url.path)"
        case .loginShell(let shell): "login shell: \(shell)"
        }
    }
}

nonisolated struct RefreshCommand: Equatable, Sendable {
    let executable: URL
    let arguments: [String]
    /// nil inherits the app's environment.
    let environment: [String: String]?
}

/// An empty per-user folder to run `claude` in. Not /tmp: anyone can write
/// there, and Claude Code reads project config like .mcp.json from its cwd.
nonisolated enum RefreshWorkingDirectory {
    static let url = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeUsage-refresh", isDirectory: true)

    static func prepare() throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
}

nonisolated enum LoginShell {
    /// From the password database, because GUI apps don't inherit `$SHELL`.
    static var path: String {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return "/bin/zsh" }
        let path = String(cString: shell)
        return path.isEmpty ? "/bin/zsh" : path
    }
}

/// Launches one refresh process and reports when it ends. A process that
/// outlives the timeout is killed; one that's merely detached is left alone.
@MainActor
final class ClaudeCLIRefresher {
    struct Exit: Equatable, Sendable {
        let pid: Int32
        let status: Int32
        let wasKilled: Bool

        var cliNotFound: Bool { !wasKilled && status == 127 }
    }

    private let timeout: Duration

    init(timeout: Duration = .seconds(30)) {
        self.timeout = timeout
    }

    /// Starts the process and returns its pid; `onExit` runs on the main actor.
    func launch(_ command: RefreshCommand, onExit: @escaping @MainActor @Sendable (Exit) -> Void) throws -> Int32 {
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        if let environment = command.environment {
            process.environment = environment
        }
        process.currentDirectoryURL = try RefreshWorkingDirectory.prepare()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { finished in
            let exit = Exit(
                pid: finished.processIdentifier,
                status: finished.terminationStatus,
                wasKilled: finished.terminationReason == .uncaughtSignal
            )
            Task { @MainActor in onExit(exit) }
        }
        try process.run()

        let timeout = self.timeout
        Task { @MainActor in
            // Suspending clock: time asleep doesn't count, so a process frozen by
            // sleep isn't killed the moment it resumes, possibly mid-Keychain-write.
            try? await Task.sleep(for: timeout, clock: .suspending)
            guard process.isRunning else { return }
            DiagnosticLog.shared.log(.refresh, "Process \(process.processIdentifier) still running after \(timeout), terminating")
            process.terminate()
        }
        return process.processIdentifier
    }
}

// MARK: - Background refresh

/// Starts background refreshes for `UsageStore` and reports when they end.
enum CredentialRefresher {
    /// Set while a refresh is running; cleared when it exits or credentials work again.
    private(set) static var hasAttemptedReauth = false

    /// Called on the main actor when the tracked refresh process exits, and
    /// from `credentialsBecameValid()`.
    static var onRefreshEnded: (() -> Void)?

    private static var activePID: Int32?
    private static var attemptsThisOutage = 0
    private static let launcher = ClaudeCLIRefresher()

    /// Called after a successful fetch. Re-arms the next outage and detaches any
    /// running refresh without signalling it: a SIGTERM mid-write makes Claude
    /// Code move its credentials out of the Keychain.
    static func credentialsBecameValid() {
        DiagnosticLog.shared.log(.refresh, "Credentials validated, clearing refresh state")
        hasAttemptedReauth = false
        attemptsThisOutage = 0
        activePID = nil
        onRefreshEnded?()
    }

    /// Lets the next `refreshInBackground()` launch even if one already ran this outage.
    static func resetAttemptGuard() {
        activePID = nil
        hasAttemptedReauth = false
    }

    /// Launches a refresh unless one is already running. Returns whether one started.
    @discardableResult
    static func refreshInBackground() -> Bool {
        guard !hasAttemptedReauth else {
            DiagnosticLog.shared.log(.refresh, "Skipped: refresh already attempted")
            return false
        }
        hasAttemptedReauth = true
        attemptsThisOutage += 1

        let cached = UserDefaults.standard.string(forKey: ClaudeCLILocator.cachedPathKey).map { URL(fileURLWithPath: $0) }
        let claude = ClaudeCLILocator.live.locate(cached: cached)
        if let claude {
            UserDefaults.standard.set(claude.path, forKey: ClaudeCLILocator.cachedPathKey)
        } else {
            findWithLoginShellInBackground()
        }
        let strategy = RefreshStrategy.choose(attempt: attemptsThisOutage, claude: claude, loginShell: LoginShell.path)

        do {
            let pid = try launcher.launch(strategy.command()) { exit in
                let note = exit.cliNotFound ? " (claude isn't on the login shell's PATH)" : ""
                DiagnosticLog.shared.log(.refresh, "Process \(exit.pid) exited with code \(exit.status)\(note)")
                guard activePID == exit.pid else { return }
                activePID = nil
                hasAttemptedReauth = false
                onRefreshEnded?()
            }
            activePID = pid
            DiagnosticLog.shared.log(.refresh, "Background claude process launched (PID \(pid), \(strategy.logDescription))")
            return true
        } catch {
            DiagnosticLog.shared.log(.refresh, "Failed to launch claude process: \(error.localizedDescription)")
            hasAttemptedReauth = false
            return false
        }
    }

    /// Caches the login shell's `claude` so the next refresh can launch it directly.
    private static func findWithLoginShellInBackground() {
        let shell = LoginShell.path
        DispatchQueue.global(qos: .utility).async {
            let found = ClaudeCLILocator.lookUpWithLoginShell(shell)
            DispatchQueue.main.async {
                if let found {
                    UserDefaults.standard.set(found.path, forKey: ClaudeCLILocator.cachedPathKey)
                    DiagnosticLog.shared.log(.refresh, "Login shell found claude at \(found.path)")
                } else {
                    DiagnosticLog.shared.log(.refresh, "Login shell couldn't find claude")
                }
            }
        }
    }
}
