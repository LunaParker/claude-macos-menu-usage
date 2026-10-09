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
        var notifier: any UsageNotifying
        var scheduler: any Scheduler
        var now: () -> Date
        var defaults: UserDefaults

        static func live(notifier: any UsageNotifying) -> Dependencies {
            Dependencies(
                credentials: KeychainCredentialSource(),
                fetcher: UsageAPIClient(),
                notifier: notifier,
                scheduler: LiveScheduler(),
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
        /// A quick retry after a transient failure.
        case retry
        /// A background `claude` refresh just exited.
        case postRefresh
    }

    /// The latest usage. Kept through transient failures; `failure` says why it may be stale.
    private(set) var snapshot: UsageSnapshot?
    private(set) var failure: UsageFailure?
    private(set) var isRefreshing = false
    private(set) var lastUpdated: Date?
    private(set) var rateLimitedUntil: Date?

    /// True while a background `claude` process is refreshing the token.
    private(set) var isRefreshingCredentials = false

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
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var retryWork: ScheduledWork?
    @ObservationIgnored private var consecutiveTransientFailures = 0

    /// Stops a background refresh whose token is still expired from starting
    /// another one straight away; cleared by a success or a manual retry.
    @ObservationIgnored private var pendingPostRefreshRetry = false

    /// Reading credentials launches `security`, so they're cached until the
    /// token expires or the API rejects it.
    @ObservationIgnored private var cachedCredentials: ClaudeCredentials?

    /// Allowed poll interval, in seconds. Below two minutes the endpoint's rate
    /// limiter starts to bite (anthropics/claude-code#31021).
    private static let pollIntervalRange = 120...300

    /// Popover opens within this long of a success show the existing snapshot.
    private let popoverDebounceInterval: TimeInterval = 15

    /// The endpoint is known for persistent 429s (anthropics/claude-code#31021),
    /// so a 429 without a usable Retry-After means five quiet minutes.
    private let rateLimitPolicy = RateLimitPolicy(defaultBackoff: 300)

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
        diagnosticsStartedAt = dependencies.now()
    }

    /// Read on every tick, so a change in Settings applies to the next sleep.
    private var pollInterval: Duration {
        let stored = dependencies.defaults[SettingsKeys.pollIntervalSeconds]
        return .seconds(Self.pollIntervalRange.contains(stored) ? stored : SettingsKeys.pollIntervalSeconds.defaultValue)
    }

    /// 30 s after the first transient failure, doubling each time, never
    /// longer than the poll interval.
    static func transientRetryDelay(afterFailures failures: Int, pollInterval: Duration) -> Duration {
        let doubling = Duration.seconds(30) * (1 << min(max(failures - 1, 0), 10))
        return min(doubling, pollInterval)
    }

    // MARK: Lifecycle

    /// Starts the background poll loop. A second call while polling is a no-op.
    func startPolling() {
        guard pollTask == nil else { return }
        CredentialRefresher.onRefreshEnded = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // credentialsBecameValid() also lands here after a normal
                // successful fetch; only a background process exit should retry.
                let wasRefreshingInBackground = self.isRefreshingCredentials
                self.isRefreshingCredentials = false
                guard wasRefreshingInBackground else { return }
                self.cachedCredentials = nil
                guard !self.pendingPostRefreshRetry else { return }
                self.pendingPostRefreshRetry = true
                self.dependencies.scheduler.schedule(after: .seconds(2)) { [weak self] in
                    await self?.refresh(trigger: .postRefresh)
                }
            }
        }
        pollTask = makePollTask(fetchImmediately: true)
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Restarts the poll loop at the current interval without fetching now.
    func reschedulePolling() {
        guard pollTask != nil else { return }
        stopPolling()
        pollTask = makePollTask(fetchImmediately: false)
    }

    /// Called when the user opens the popover.
    func refreshNow() {
        Task { await refresh(trigger: .popover) }
    }

    /// "Try again" and the Reauthenticate notification: drop the credential
    /// cache and the retry guards, then refresh, which re-reads the Keychain and
    /// only launches `claude` if the token really has expired.
    func manualRetry() {
        cachedCredentials = nil
        pendingPostRefreshRetry = false
        // Resetting while a refresh runs would start a second `claude` beside it.
        if !isRefreshingCredentials {
            CredentialRefresher.resetAttemptGuard()
        }
        Task { await refresh(trigger: .manual) }
    }

    /// Wipes the diagnostic counters so the request rate can be measured afresh.
    func resetDiagnostics() {
        networkRequestCount = 0
        lastNetworkAttemptAt = nil
        diagnosticsStartedAt = dependencies.now()
    }

    private func makePollTask(fetchImmediately: Bool) -> Task<Void, Never> {
        Task { [weak self] in
            var shouldFetch = fetchImmediately
            while !Task.isCancelled {
                guard let self else { return }
                if shouldFetch {
                    await self.refresh(trigger: .poll)
                }
                shouldFetch = true
                try? await Task.sleep(for: self.pollInterval)
            }
        }
    }

    // MARK: Refresh

    /// Fetches usage unless a refresh is in flight, the popover debounce
    /// applies or a 429 cooldown is running.
    func refresh(trigger: Trigger = .manual) async {
        guard !isRefreshing else { return }
        let now = dependencies.now()
        if trigger == .popover, let lastUpdated, now.timeIntervalSince(lastUpdated) < popoverDebounceInterval {
            return
        }
        if let rateLimitedUntil, now < rateLimitedUntil {
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

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
            cachedCredentials = nil
            DiagnosticLog.shared.log(.refresh, "Token expired, attempting background refresh")
            handleAuthenticationLost()
            return
        }

        await fetchUsage(using: credentials, retryOnRotation: true)
    }

    private func loadCredentials() async throws -> ClaudeCredentials {
        if let cached = cachedCredentials, !cached.isExpired {
            DiagnosticLog.shared.log(.keychain, "Using cached credentials")
            return cached
        }
        DiagnosticLog.shared.log(.keychain, "Cache miss, loading from Keychain")
        let fresh = try await dependencies.credentials.load()
        cachedCredentials = fresh.credentials
        keychainReadMethod = fresh.method
        return fresh.credentials
    }

    /// One request against the usage endpoint. A 401 on a cached token usually
    /// means Claude Code rotated it, so with `retryOnRotation` the Keychain is
    /// re-read and a newer token retried once, silently.
    private func fetchUsage(using credentials: ClaudeCredentials, retryOnRotation: Bool) async {
        networkRequestCount += 1
        lastNetworkAttemptAt = dependencies.now()
        DiagnosticLog.shared.log(.api, "Request #\(networkRequestCount) started")

        do {
            let response = try await dependencies.fetcher.fetch(accessToken: credentials.accessToken)
            DiagnosticLog.shared.log(.api, "HTTP 200 — usage data received")
            succeeded(with: response)
        } catch UsageAPIError.rateLimited(let retryAfter) {
            let backoff = rateLimitPolicy.cooldown(retryAfter: retryAfter)
            DiagnosticLog.shared.log(.api, "HTTP 429 — rate limited, backoff \(Int(backoff))s")
            let until = dependencies.now().addingTimeInterval(backoff)
            rateLimitedUntil = until
            failure = .rateLimited(until: until)
        } catch UsageAPIError.unauthorized {
            DiagnosticLog.shared.log(.api, "HTTP 401/403 — token rejected")
            cachedCredentials = nil
            if retryOnRotation,
               let rotated = Self.rotatedCredentials(replacing: credentials, reloaded: try? await loadCredentials()) {
                DiagnosticLog.shared.log(.keychain, "Keychain holds a newer token — retrying silently")
                await fetchUsage(using: rotated, retryOnRotation: false)
                return
            }
            handleAuthenticationLost()
        } catch UsageAPIError.transport(let error) {
            DiagnosticLog.shared.log(.api, "API error: Network error: \(error.localizedDescription)")
            failedTransiently(.offline(error.localizedDescription))
        } catch UsageAPIError.http(let status) {
            DiagnosticLog.shared.log(.api, "API error: HTTP \(status)")
            failedTransiently(.server(status: status))
        } catch {
            DiagnosticLog.shared.log(.api, "API error: \(error.localizedDescription)")
            failedTransiently(.unexpectedResponse)
        }
    }

    private func succeeded(with response: UsageResponse) {
        CredentialRefresher.credentialsBecameValid()
        pendingPostRefreshRetry = false
        retryWork?.cancel()
        retryWork = nil
        consecutiveTransientFailures = 0

        let snapshot = Self.buildSnapshot(from: response, fetchedAt: dependencies.now())
        self.snapshot = snapshot
        lastUpdated = snapshot.fetchedAt
        failure = nil
        rateLimitedUntil = nil
        dependencies.notifier.authenticationRestored()
        dependencies.notifier.evaluateThresholds(snapshot: snapshot)
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

    /// The token expired or was rejected: notify, launch the background refresh
    /// (a no-op when one is running) and say which of the two is happening.
    private func handleAuthenticationLost() {
        dependencies.notifier.authenticationLost()
        if CredentialRefresher.refreshInBackground() {
            isRefreshingCredentials = true
        }
        failure = isRefreshingCredentials ? .refreshingSignIn : .signInExpired(nextAttempt: nil)
    }
}
