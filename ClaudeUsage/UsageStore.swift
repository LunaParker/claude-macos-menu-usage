//
//  UsageStore.swift
//  Menu Bar Usage for Claude
//
//  The observable store behind the menu bar and popover: polling,
//  credential handling and fetch state.
//

import Foundation
import Observation

/// The single source of truth the popover observes. Polls from the moment
/// onboarding finishes until the app quits, so the menu bar stays fresh.
@Observable
@MainActor
final class UsageStore {
    struct Dependencies {
        var credentials: any CredentialSource
        var fetcher: any UsageFetching
        var resets: any LimitResetsFetching
        /// The installed `claude` version, which the resets request has to name.
        var cliVersion: @Sendable () async -> String?
        var refresher: any CredentialRefreshing
        var notifier: any UsageNotifying
        var scheduler: any Scheduler
        var display: any DisplayState
        var now: () -> Date
        var defaults: UserDefaults

        static func live(notifier: any UsageNotifying) -> Dependencies {
            Dependencies(
                credentials: KeychainCredentialSource(),
                fetcher: UsageAPIClient(),
                resets: LimitResetsClient(),
                cliVersion: { await Task.detached { ClaudeCLIVersion.installed() }.value },
                refresher: ClaudeRefreshService(),
                notifier: notifier,
                scheduler: LiveScheduler(),
                display: DisplaySleepMonitor(),
                now: Date.init,
                defaults: .standard
            )
        }
    }

    enum Trigger {
        case poll
        /// The popover opened; debounced against the last success.
        case popover
        /// "Try again", the Reauthenticate notification or Force Refresh.
        case manual
        /// A quick retry after a transient failure, or the next refresh attempt.
        case retry
        /// A background `claude` refresh just exited.
        case postRefresh
        /// An App Intent asked; like `.manual`, but skipped while the displays sleep.
        case intent
        /// The displays woke; debounced like `.popover`.
        case wake
    }

    /// The latest usage. Kept through transient failures; `failure` says why it may be stale.
    private(set) var snapshot: UsageSnapshot?
    private(set) var failure: UsageFailure?
    private(set) var isRefreshing = false
    private(set) var lastUpdated: Date?
    private(set) var rateLimitedUntil: Date?

    /// The usable limit resets from the last check; nil before one, or when none are offered.
    private(set) var limitResets: LimitResets?
    /// When the resets were last checked, whatever the answer.
    private(set) var limitResetsCheckedAt: Date?
    /// Why no resets are offered (`surface`, `claude version unknown`), for the Developer tab.
    private(set) var limitResetsUnavailableReason: String?

    /// Where the background token refresh stands.
    private(set) var auth: AuthPhase = .ok

    /// True from a refresh's launch until the store has checked its result.
    var isRefreshingCredentials: Bool {
        switch auth {
        case .refreshing, .checking: true
        case .ok, .waiting: false
        }
    }

    /// Which read path last produced credentials, for the Developer tab.
    private(set) var keychainReadMethod: KeychainReadMethod?

    var presentation: UsagePresentation {
        UsagePresentation(snapshot: snapshot, failure: failure)
    }

    // MARK: Diagnostic counters (surfaced on the Developer tab)

    /// When the diagnostic measurement window started; reset by `resetDiagnostics()`.
    private(set) var diagnosticsStartedAt: Date

    /// Requests that reached the network. Calls skipped by the debounce,
    /// cooldown or re-entrancy guard aren't counted.
    private(set) var networkRequestCount: Int = 0

    /// The most recent network attempt, whatever its outcome.
    private(set) var lastNetworkAttemptAt: Date?

    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private var pollWork: ScheduledWork?
    @ObservationIgnored private var isPolling = false
    @ObservationIgnored private var retryWork: ScheduledWork?
    @ObservationIgnored private var authWork: ScheduledWork?
    @ObservationIgnored private var wakeWork: ScheduledWork?
    @ObservationIgnored private var consecutiveTransientFailures = 0
    @ObservationIgnored private var resetsLastAttemptAt: Date?

    /// A post-refresh check or manual retry that arrived mid-refresh runs once that ends.
    @ObservationIgnored private var rerunRequested = false

    /// Reading credentials launches `security`, so they're cached until the token
    /// is within `tokenRereadMargin` of expiry or the API rejects it.
    @ObservationIgnored private var cachedCredentials: ClaudeCredentials?

    /// The last token read from the Keychain, so the log can say when it changed.
    @ObservationIgnored private var lastTokenFingerprint: String?

    /// Claude Code replaces its token 5 minutes before expiry, so inside this
    /// margin every request re-reads the Keychain instead of trusting the cache.
    private let tokenRereadMargin: TimeInterval = 10 * 60

    /// Popover opens and wakes within this long of a success show the existing snapshot.
    private let popoverDebounceInterval: TimeInterval = 60

    /// The endpoint is known for persistent 429s (anthropics/claude-code#31021),
    /// so a 429 without a usable Retry-After means five quiet minutes.
    private let rateLimitPolicy = RateLimitPolicy(defaultBackoff: 300)

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
        diagnosticsStartedAt = dependencies.now()
        dependencies.display.onWake = { [weak self] in self?.displaysWoke() }
    }

    /// Read whenever a poll is booked, so a change in Settings applies at once.
    var pollInterval: Duration {
        .seconds(PollInterval.effectiveSeconds(stored: dependencies.defaults[SettingsKeys.pollIntervalSeconds]))
    }

    /// 30 s after the first transient failure, doubling each time, never
    /// longer than the poll interval.
    static func transientRetryDelay(afterFailures failures: Int, pollInterval: Duration) -> Duration {
        let doubling = Duration.seconds(30) * (1 << min(max(failures - 1, 0), 10))
        return min(doubling, pollInterval)
    }

    // MARK: Lifecycle

    /// Fetches now and keeps polling. A second call while polling is a no-op.
    func startPolling() {
        guard !isPolling else { return }
        isPolling = true
        pollWork = dependencies.scheduler.schedule(after: .zero) { [weak self] in
            await self?.poll()
        }
    }

    func stopPolling() {
        isPolling = false
        pollWork?.cancel()
        pollWork = nil
    }

    /// Books the next poll one interval from now, without fetching.
    func reschedulePolling() {
        guard isPolling else { return }
        scheduleNextPoll()
    }

    private func poll() async {
        // This booking has fired; cancelling it now would cancel the poll itself.
        pollWork = nil
        await refresh(trigger: .poll)
        scheduleNextPoll()
    }

    /// The next poll comes a full interval after now. Every success books it
    /// too, so a popover open or a retry replaces a poll instead of adding one.
    private func scheduleNextPoll() {
        guard isPolling else { return }
        pollWork?.cancel()
        pollWork = dependencies.scheduler.schedule(after: pollInterval) { [weak self] in
            await self?.poll()
        }
    }

    /// Called when the user opens the popover.
    func refreshNow() {
        Task { await refresh(trigger: .popover) }
    }

    /// "Try again" and the Reauthenticate notification.
    func manualRetry() {
        Task { await retryManually() }
    }

    /// Drops the credential cache and any refresh backoff, then refreshes, which
    /// re-reads the Keychain and only launches `claude` if the token is unusable.
    /// A refresh already running is left alone; its exit triggers the check.
    func retryManually() async {
        cachedCredentials = nil
        if case .waiting = auth {
            auth = .ok
            authWork?.cancel()
        }
        await refresh(trigger: .manual)
    }

    /// Fetches shortly after the displays wake, giving the network a moment to
    /// come back. Nothing is read before onboarding has finished.
    func displaysWoke() {
        guard dependencies.defaults[SettingsKeys.hasCompletedOnboarding] else { return }
        wakeWork?.cancel()
        wakeWork = dependencies.scheduler.schedule(after: .seconds(5)) { [weak self] in
            await self?.refresh(trigger: .wake)
        }
    }

    /// Wipes the diagnostic counters so the request rate can be measured afresh.
    func resetDiagnostics() {
        networkRequestCount = 0
        lastNetworkAttemptAt = nil
        diagnosticsStartedAt = dependencies.now()
    }

    /// The latest raw response, for the Developer tab's Copy button.
    var lastResponseBody: Data? { dependencies.fetcher.lastResponseBody }

    // MARK: App Intents

    /// What the App Intents ask for: the data on hand, fetched first when there
    /// is none or when asked, with a fetch already under way awaited instead.
    func currentUsage(refreshFirst: Bool) async throws(UsageRequestError) -> UsageSnapshot {
        guard dependencies.defaults[SettingsKeys.hasCompletedOnboarding] else { throw .notSetUp }
        if refreshFirst || snapshot == nil {
            if isRefreshing {
                await waitForRefresh()
            } else {
                await refresh(trigger: .intent)
            }
        }
        // Like the popover: data on hand is withheld once only the user can fix things.
        if let snapshot, !(failure?.needsUser ?? false) { return snapshot }
        if let failure { throw .unavailable(failure) }
        throw .noData
    }

    /// Up to 30 s, which outlasts the fetch timeout.
    private func waitForRefresh() async {
        var waited = 0
        while isRefreshing, waited < 300 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
    }

    // MARK: Refresh

    /// Fetches usage unless a refresh is in flight, the popover debounce
    /// applies or a 429 cooldown is running.
    func refresh(trigger: Trigger = .manual) async {
        guard !isRefreshing else {
            if trigger == .postRefresh || trigger == .manual {
                rerunRequested = true
            }
            return
        }
        // Nobody sees a refresh while the displays sleep, and a `claude` launched
        // into a DarkWake freezes mid-refresh when the Mac sleeps again.
        if trigger != .manual, dependencies.display.displaysAsleep {
            return
        }
        let now = dependencies.now()
        if trigger == .popover || trigger == .wake,
           let lastUpdated, now.timeIntervalSince(lastUpdated) < popoverDebounceInterval {
            DiagnosticLog.shared.log(.api, "Refresh skipped (\(trigger)): last success \(Int(now.timeIntervalSince(lastUpdated))) s ago")
            return
        }
        if let rateLimitedUntil, now < rateLimitedUntil {
            let minutes = Int((rateLimitedUntil.timeIntervalSince(now) / 60).rounded(.up))
            DiagnosticLog.shared.log(.api, "Refresh skipped (\(trigger)): rate limited for another \(minutes) min")
            return
        }

        isRefreshing = true
        await performRefresh(trigger: trigger)
        isRefreshing = false

        if rerunRequested {
            rerunRequested = false
            await refresh(trigger: .manual)
        }
    }

    private func performRefresh(trigger: Trigger) async {
        let credentials: ClaudeCredentials
        do {
            credentials = try await loadCredentials()
        } catch KeychainError.itemNotFound {
            cachedCredentials = nil
            failure = .signedOut
            dependencies.notifier.authenticationLost()
            return
        } catch {
            cachedCredentials = nil
            failure = .credentialsUnreadable(error.localizedDescription)
            return
        }

        if credentials.isExpired {
            DiagnosticLog.shared.log(.refresh, "Token expired")
            handleUnusableToken()
            return
        }

        await fetchUsage(using: credentials, reason: "\(trigger)", retryOnRotation: true)
    }

    private func loadCredentials() async throws -> ClaudeCredentials {
        if let cached = cachedCredentials, !cached.isExpired {
            let left = cached.expirationDate.timeIntervalSince(dependencies.now())
            guard left <= tokenRereadMargin else {
                DiagnosticLog.shared.log(.keychain, "Using cached credentials")
                return cached
            }
            DiagnosticLog.shared.log(.keychain, "Token \(cached.fingerprint) expires within \(Int(tokenRereadMargin / 60)) min; re-reading the Keychain in case Claude Code replaced it")
        } else {
            DiagnosticLog.shared.log(.keychain, "Cache miss, loading from Keychain")
        }
        let fresh = try await dependencies.credentials.load()
        cachedCredentials = fresh.credentials
        keychainReadMethod = fresh.method
        let fingerprint = fresh.credentials.fingerprint
        if let previous = lastTokenFingerprint, previous != fingerprint {
            DiagnosticLog.shared.log(.keychain, "Keychain token changed: \(previous) → \(fingerprint)")
        }
        lastTokenFingerprint = fingerprint
        return fresh.credentials
    }

    /// Drops the cached token and reads the Keychain; nil when the read fails.
    private func reloadCredentials() async -> ClaudeCredentials? {
        cachedCredentials = nil
        return try? await loadCredentials()
    }

    /// One request against the usage endpoint. With `retryOnRotation`, a 401 or 429
    /// re-reads the Keychain and retries once, silently, if it holds a newer token.
    private func fetchUsage(using credentials: ClaudeCredentials, reason: String, retryOnRotation: Bool) async {
        networkRequestCount += 1
        lastNetworkAttemptAt = dependencies.now()
        let expiry = credentials.expirationDate.formatted(date: .omitted, time: .shortened)
        DiagnosticLog.shared.log(.api, "Request #\(networkRequestCount) started (\(reason), token \(credentials.fingerprint), expires \(expiry))")

        do {
            let response = try await dependencies.fetcher.fetch(accessToken: credentials.accessToken)
            DiagnosticLog.shared.log(.api, "HTTP 200 — usage data received")
            let previous = snapshot
            succeeded(with: response)
            await refreshResets(previous: previous, accessToken: credentials.accessToken)
        } catch UsageAPIError.rateLimited(let retryAfter) {
            let backoff = rateLimitPolicy.cooldown(retryAfter: retryAfter)
            DiagnosticLog.shared.log(.api, "HTTP 429 on token \(credentials.fingerprint) — Retry-After \(retryAfter.map { "\(Int($0)) s" } ?? "missing")")
            if retryOnRotation, let rotated = await rotatedAfterRejection(of: credentials) {
                await fetchUsage(using: rotated, reason: "retry after 429", retryOnRotation: false)
                return
            }
            DiagnosticLog.shared.log(.api, "Rate limited; cooling down for \(Int(backoff)) s")
            let until = dependencies.now().addingTimeInterval(backoff)
            rateLimitedUntil = until
            failure = .rateLimited(until: until)
        } catch UsageAPIError.unauthorized {
            DiagnosticLog.shared.log(.api, "HTTP 401/403 — token \(credentials.fingerprint) rejected")
            cachedCredentials = nil
            if retryOnRotation, let rotated = await rotatedAfterRejection(of: credentials) {
                await fetchUsage(using: rotated, reason: "retry after 401", retryOnRotation: false)
                return
            }
            handleUnusableToken()
        } catch UsageAPIError.transport(let error) {
            // The caller's task was cancelled (a poll-interval change, a stopped
            // Shortcut): nothing about the network failed.
            if (error as? URLError)?.code == .cancelled {
                DiagnosticLog.shared.log(.api, "Request cancelled")
                return
            }
            DiagnosticLog.shared.log(.api, "API error: Network error: \(error.localizedDescription)")
            failedTransiently(.offline(error.localizedDescription))
        } catch UsageAPIError.http(let status) {
            DiagnosticLog.shared.log(.api, "API error: HTTP \(status)")
            failedTransiently(.server(status: status))
        } catch is CancellationError {
            DiagnosticLog.shared.log(.api, "Request cancelled")
        } catch {
            DiagnosticLog.shared.log(.api, "API error: \(error.localizedDescription)")
            failedTransiently(.unexpectedResponse)
        }
    }

    private func succeeded(with response: UsageResponse) {
        if auth != .ok {
            // A refresh still running is detached, not killed: a SIGTERM mid-write
            // makes Claude Code move its credentials out of the Keychain.
            DiagnosticLog.shared.log(.refresh, "Credentials work again, ending the refresh outage")
            auth = .ok
            authWork?.cancel()
            authWork = nil
        }
        retryWork?.cancel()
        retryWork = nil
        consecutiveTransientFailures = 0
        scheduleNextPoll()

        let snapshot = Self.buildSnapshot(from: response, fetchedAt: dependencies.now())
        self.snapshot = snapshot
        lastUpdated = snapshot.fetchedAt
        failure = nil
        rateLimitedUntil = nil
        dependencies.notifier.authenticationRestored()
        dependencies.notifier.evaluateThresholds(snapshot: snapshot)
    }

    // MARK: Limit resets

    /// After a usage success: checks the resets when the policy says so, then
    /// hands them to the notifier. Its failures never touch the bars or `failure`.
    private func refreshResets(previous: UsageSnapshot?, accessToken: String) async {
        guard let current = snapshot else { return }
        if ResetsRefreshPolicy.isDue(lastAttempt: resetsLastAttemptAt, previous: previous, current: current, now: dependencies.now()) {
            resetsLastAttemptAt = dependencies.now()
            await fetchResets(accessToken: accessToken)
        }
        // Not before a first answer: the alerts would take every held reset for a new one.
        guard limitResetsCheckedAt != nil, let snapshot else { return }
        let simulate = dependencies.defaults[SettingsKeys.simulateLimitReset]
        let shown = LimitResets.displayed(limitResets, simulate: simulate, now: dependencies.now()) ?? LimitResets(grants: [])
        dependencies.notifier.evaluateResets(snapshot: snapshot, resets: shown)
    }

    private func fetchResets(accessToken: String) async {
        guard let version = await dependencies.cliVersion() else {
            DiagnosticLog.shared.log(.api, "Limit resets not checked: claude version unknown")
            limitResets = nil
            limitResetsUnavailableReason = "claude version unknown"
            limitResetsCheckedAt = dependencies.now()
            return
        }
        networkRequestCount += 1
        lastNetworkAttemptAt = dependencies.now()
        DiagnosticLog.shared.log(.api, "Request #\(networkRequestCount) started (limit resets, claude \(version))")
        do {
            let block = try await dependencies.resets.fetchResets(accessToken: accessToken, cliVersion: version)
            let now = dependencies.now()
            if let block, block.eligible == true {
                let resets = LimitResets(block: block, now: now)
                limitResets = resets
                limitResetsUnavailableReason = nil
                DiagnosticLog.shared.log(.api, "Limit resets: \(resets.grants.count) usable of \(block.grants.count) grants")
            } else {
                let reason = block.map { $0.ineligibleReason ?? "not offered" } ?? "no resets in the response"
                limitResets = nil
                limitResetsUnavailableReason = reason
                DiagnosticLog.shared.log(.api, "Limit resets not offered: \(reason)")
            }
            limitResetsCheckedAt = now
        } catch {
            DiagnosticLog.shared.log(.api, "Limit resets request failed: \(error.localizedDescription)")
        }
    }

    /// Keeps the snapshot and retries sooner than the next poll.
    private func failedTransiently(_ failure: UsageFailure) {
        self.failure = failure
        consecutiveTransientFailures += 1
        let delay = Self.transientRetryDelay(afterFailures: consecutiveTransientFailures, pollInterval: pollInterval)
        retryWork?.cancel()
        retryWork = dependencies.scheduler.schedule(after: delay) { [weak self] in
            await self?.refresh(trigger: .retry)
        }
    }

    /// Re-reads the Keychain after a rejection and returns a newer token to retry with, if any.
    private func rotatedAfterRejection(of rejected: ClaudeCredentials) async -> ClaudeCredentials? {
        let reloaded = await reloadCredentials()
        guard let rotated = Self.rotatedCredentials(replacing: rejected, reloaded: reloaded) else {
            let found = reloaded.map {
                $0.accessToken == rejected.accessToken ? "the same token \($0.fingerprint)" : "token \($0.fingerprint), already expired"
            } ?? "nothing readable"
            DiagnosticLog.shared.log(.keychain, "Keychain holds \(found); not retrying")
            return nil
        }
        DiagnosticLog.shared.log(.keychain, "Keychain holds a newer token \(rotated.fingerprint) — retrying silently")
        return rotated
    }

    /// Returns reloaded credentials when they carry a different, unexpired token;
    /// nil when the re-read failed, found the same token or found an expired one.
    static func rotatedCredentials(
        replacing rejected: ClaudeCredentials,
        reloaded: ClaudeCredentials?
    ) -> ClaudeCredentials? {
        guard let reloaded,
              reloaded.accessToken != rejected.accessToken,
              !reloaded.isExpired
        else { return nil }
        return reloaded
    }

    // MARK: Background token refresh

    /// The token expired or was rejected and no rotated one was found.
    private func handleUnusableToken() {
        cachedCredentials = nil
        switch auth {
        case .ok:
            startRefresh(attempt: 1)
        case .refreshing:
            failure = .refreshingSignIn
        case .checking(let attempt, let strategy):
            attemptFailed(attempt: attempt, strategy: strategy)
        case .waiting(let failedAttempts, let until):
            // A second of slack, so a scheduled retry that wakes a hair early still starts.
            if dependencies.now().addingTimeInterval(1) >= until {
                startRefresh(attempt: failedAttempts + 1)
            }
        }
    }

    private func startRefresh(attempt: Int) {
        let start = dependencies.refresher.start(attempt: attempt) { [weak self] exit in
            self?.refreshExited(exit)
        }
        switch start {
        case .started(let pid, let strategy):
            auth = .refreshing(attempt: attempt, pid: pid, strategy: strategy)
            failure = .refreshingSignIn
        case .failed:
            attemptFailed(attempt: attempt, strategy: nil)
        }
    }

    private func refreshExited(_ exit: ClaudeCLIRefresher.Exit) {
        let note = exit.cliNotFound ? " (claude isn't on the login shell's PATH)" : exit.wasKilled ? " (killed)" : ""
        DiagnosticLog.shared.log(.refresh, "Process \(exit.pid) exited with code \(exit.status)\(note)")
        guard case .refreshing(let attempt, let pid, let strategy) = auth, pid == exit.pid else {
            DiagnosticLog.shared.log(.refresh, "No longer waiting on process \(exit.pid); ignoring its exit")
            return
        }

        if exit.cliNotFound {
            let until = dependencies.now().addingTimeInterval(RefreshPolicy.cliNotFoundRetry)
            auth = .waiting(failedAttempts: attempt, until: until)
            failure = .claudeNotFound
            dependencies.notifier.authenticationLost()
            scheduleRefreshAttempt(after: RefreshPolicy.cliNotFoundRetry)
            return
        }

        auth = .checking(attempt: attempt, strategy: strategy)
        cachedCredentials = nil
        authWork?.cancel()
        authWork = dependencies.scheduler.schedule(after: .seconds(2)) { [weak self] in
            await self?.refresh(trigger: .postRefresh)
        }
    }

    /// The attempt ended without a working token: back off, and tell the user
    /// when the policy says the outage is real.
    private func attemptFailed(attempt: Int, strategy: RefreshStrategy?) {
        let decision = RefreshPolicy.afterFailure(attempt: attempt, strategy: strategy)
        let until = dependencies.now().addingTimeInterval(decision.retryIn)
        auth = .waiting(failedAttempts: attempt, until: until)
        DiagnosticLog.shared.log(.refresh, "Attempt \(attempt) didn't produce a working token; next attempt in \(Int(decision.retryIn)) s")
        if decision.notify {
            failure = .signInExpired(nextAttempt: until)
            dependencies.notifier.authenticationLost()
        } else {
            failure = .refreshingSignIn
        }
        scheduleRefreshAttempt(after: decision.retryIn)
    }

    private func scheduleRefreshAttempt(after seconds: TimeInterval) {
        authWork?.cancel()
        authWork = dependencies.scheduler.schedule(after: .seconds(seconds)) { [weak self] in
            await self?.refresh(trigger: .retry)
        }
    }
}
