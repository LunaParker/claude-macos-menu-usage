//
//  UsageStoreFakes.swift
//  ClaudeUsageTests
//
//  Test doubles for UsageStore's dependencies. None of them touch the
//  Keychain, the network or the real preferences.
//

import Foundation
@testable import ClaudeUsage

/// Stands in for the Keychain; tests change `next` between refreshes.
nonisolated final class FakeKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var storedNext: Result<ClaudeCredentials, KeychainError>
    private var storedLoads = 0

    init(_ initial: Result<ClaudeCredentials, KeychainError>) {
        storedNext = initial
    }

    var next: Result<ClaudeCredentials, KeychainError> {
        get { lock.withLock { storedNext } }
        set { lock.withLock { storedNext = newValue } }
    }

    var loads: Int { lock.withLock { storedLoads } }

    var source: KeychainCredentialSource {
        KeychainCredentialSource { [self] in
            try lock.withLock {
                storedLoads += 1
                return LoadedCredentials(credentials: try storedNext.get(), method: .securityCLI)
            }
        }
    }
}

final class FakeFetcher: UsageFetching {
    /// Consumed in order; the last one repeats.
    var responses: [Result<UsageResponse, UsageAPIError>] = [.success(.sample())]
    /// How long each fetch stays in flight, for tests that need to observe one.
    var delay: Duration = .zero
    var lastResponseBody: Data?
    private(set) var tokens: [String] = []

    func fetch(accessToken: String) async throws -> UsageResponse {
        tokens.append(accessToken)
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        let next = responses.count > 1 ? responses.removeFirst() : responses[0]
        return try next.get()
    }
}

final class FakeResetsFetcher: LimitResetsFetching {
    /// Consumed in order; the last one repeats.
    var responses: [Result<LimitResetsBlock?, UsageAPIError>] = [.success(.eligibleSample())]
    private(set) var calls: [(token: String, version: String)] = []

    func fetchResets(accessToken: String, cliVersion: String) async throws -> LimitResetsBlock? {
        calls.append((accessToken, cliVersion))
        let next = responses.count > 1 ? responses.removeFirst() : responses[0]
        return try next.get()
    }
}

/// The installed `claude` version the store's dependency reports.
nonisolated final class FakeCLIVersion: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String? = "2.1.322"

    var value: String? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Records refresh launches; the test decides when and how each one exits.
final class FakeRefresher: CredentialRefreshing {
    struct Start {
        let attempt: Int
        let pid: Int32
        let strategy: RefreshStrategy
    }

    var claudeInstalled = true
    private(set) var starts: [Start] = []
    private var onExit: (@MainActor @Sendable (ClaudeCLIRefresher.Exit) -> Void)?

    func start(attempt: Int, onExit: @escaping @MainActor @Sendable (ClaudeCLIRefresher.Exit) -> Void) -> RefreshStart {
        let claude = claudeInstalled ? URL(fileURLWithPath: "/fake/bin/claude") : nil
        let start = Start(
            attempt: attempt,
            pid: Int32(1000 + starts.count),
            strategy: RefreshStrategy.choose(attempt: attempt, claude: claude, loginShell: "/bin/zsh")
        )
        starts.append(start)
        self.onExit = onExit
        return .started(pid: start.pid, strategy: start.strategy)
    }

    /// Ends the most recent launch with `status`.
    func exitLast(status: Int32 = 0) {
        guard let last = starts.last else { return }
        onExit?(ClaudeCLIRefresher.Exit(pid: last.pid, status: status, wasKilled: false))
    }
}

final class FakeDisplay: DisplayState {
    var displaysAsleep = false
    var onWake: (() -> Void)?

    func sleep() { displaysAsleep = true }

    func wake() {
        displaysAsleep = false
        onWake?()
    }
}

final class FakeNotifier: UsageNotifying {
    private(set) var lost = 0
    private(set) var restored = 0
    private(set) var evaluated: [UsageSnapshot] = []
    private(set) var evaluatedResets: [LimitResets] = []

    func authenticationLost() { lost += 1 }
    func authenticationRestored() { restored += 1 }
    func evaluateThresholds(snapshot: UsageSnapshot) { evaluated.append(snapshot) }
    func evaluateResets(snapshot: UsageSnapshot, resets: LimitResets) { evaluatedResets.append(resets) }
}

/// Holds scheduled work until the test runs it, all at once or by the clock.
final class ManualScheduler: Scheduler {
    private final class Item {
        let delay: Duration
        let dueAt: Date
        let work: @MainActor () async -> Void
        var cancelled = false
        init(delay: Duration, dueAt: Date, work: @escaping @MainActor () async -> Void) {
            self.delay = delay
            self.dueAt = dueAt
            self.work = work
        }
    }

    private let now: () -> Date
    private var items: [Item] = []

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    var pendingDelays: [Duration] { items.filter { !$0.cancelled }.map(\.delay) }

    func schedule(after delay: Duration, _ work: @escaping @MainActor () async -> Void) -> ScheduledWork {
        let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        let item = Item(delay: delay, dueAt: now().addingTimeInterval(seconds), work: work)
        items.append(item)
        return ScheduledWork { item.cancelled = true }
    }

    /// Runs everything pending now, in the order it was scheduled.
    func runPending() async {
        let due = items.filter { !$0.cancelled }
        items.removeAll()
        for item in due {
            await item.work()
        }
    }

    /// Runs the work whose delay has elapsed on the clock, in the order it was scheduled.
    func runDue() async {
        let now = now()
        let due = items.filter { !$0.cancelled && $0.dueAt <= now }
        items.removeAll { $0.cancelled || $0.dueAt <= now }
        for item in due {
            await item.work()
        }
    }
}

final class TestClock {
    var now = Date()
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// Wires a store to fakes.
final class StoreHarness {
    let keychain = FakeKeychain(.success(TestCredentials.valid(token: "token-1")))
    let fetcher = FakeFetcher()
    let resets = FakeResetsFetcher()
    let cliVersion = FakeCLIVersion()
    let refresher = FakeRefresher()
    let notifier = FakeNotifier()
    let display = FakeDisplay()
    let clock: TestClock
    /// Runs on the same clock as the store, so `runDue()` follows `clock.advance`.
    let scheduler: ManualScheduler
    let defaults: UserDefaults = {
        let defaults = TestDefaults.make()
        defaults.set(true, forKey: SettingsKeys.hasCompletedOnboarding.name)
        return defaults
    }()

    init() {
        let clock = TestClock()
        self.clock = clock
        scheduler = ManualScheduler(now: { clock.now })
    }

    /// `scheduler` swaps in a real one for tests about live task behaviour.
    func makeStore(scheduler: (any Scheduler)? = nil) -> UsageStore {
        let clock = self.clock
        let cliVersion = self.cliVersion
        return UsageStore(dependencies: .init(
            credentials: keychain.source,
            fetcher: fetcher,
            resets: resets,
            cliVersion: { cliVersion.value },
            refresher: refresher,
            notifier: notifier,
            scheduler: scheduler ?? self.scheduler,
            display: display,
            now: { clock.now },
            defaults: defaults
        ))
    }
}

extension LimitResetsBlock {
    /// One weekly reset with no expiry, so it holds whatever the harness clock says.
    static func eligibleSample() -> LimitResetsBlock {
        LimitResetsBlock(eligible: true, ineligibleReason: nil, grants: [
            Grant(id: "weekly", resetsLeft: 1, startsAt: nil, endsAt: nil, clears: ["seven_day", "seven_day_overage_included"], paused: false, usableNow: true),
        ])
    }
}

extension UsageResponse {
    static func sample(session: Double = 42, weekly: Double = 10) -> UsageResponse {
        UsageResponse(
            fiveHour: UsageWindow(utilization: session, resetsAt: nil),
            sevenDay: UsageWindow(utilization: weekly, resetsAt: nil),
            limits: nil,
            extraUsage: nil
        )
    }
}
