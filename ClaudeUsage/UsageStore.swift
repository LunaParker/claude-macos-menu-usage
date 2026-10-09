//
//  UsageStore.swift
//  Menu Bar Usage for Claude
//
//  The observable store behind the menu bar and popover: polling,
//  credential handling and fetch state.
//

import Foundation
import Observation

// MARK: - Observable store

/// The single source of truth the popover observes. Lives for the lifetime
/// of the app and polls on a fixed interval from the moment the user
/// finishes onboarding until the app quits, so the menu bar label stays
/// fresh even while the popover is closed.
@Observable
@MainActor
final class UsageStore {
    enum State {
        case idle
        case loading
        case loaded(UsageSnapshot)
        case missingCredentials
        case error(String)
    }

    private(set) var state: State = .idle
    private(set) var isRefreshing: Bool = false
    private(set) var lastUpdated: Date?

    /// True while a background `claude` process is actively running to
    /// refresh credentials. Used by the popover to swap the "Try again"
    /// button for a progress indicator.
    private(set) var isRefreshingCredentials: Bool = false

    // MARK: Diagnostic counters (surfaced on the Developer tab)

    /// When the diagnostic measurement window started. Equal to app launch
    /// time by default, but `resetDiagnostics()` resets this to `now` so
    /// users can benchmark the request rate from a fresh baseline.
    private(set) var diagnosticsStartedAt: Date = Date()

    /// Total number of HTTP requests actually dispatched to
    /// `/api/oauth/usage` during the current measurement window. Does
    /// **not** include calls skipped by the debounce / rate-limit
    /// cooldown / re-entrancy guard — only the ones that hit the network.
    private(set) var networkRequestCount: Int = 0

    /// Timestamp of the most recent network attempt, regardless of outcome.
    /// Separate from `lastUpdated`, which only tracks successful responses.
    private(set) var lastNetworkAttemptAt: Date?

    /// Exposed (read-only) for the Developer tab so it can show a cooldown
    /// indicator. Still mutated internally by `refresh()`.
    private(set) var rateLimitedUntil: Date?

    /// Which keychain read path last succeeded. Updated after every
    /// successful credential load so the Developer tab can display it.
    private(set) var keychainReadMethod: KeychainReadMethod?

    /// Guards against a feedback loop: background `claude` exits →
    /// retry → still expired → launches another `claude` → exits →
    /// retry → … The flag is set when a post-refresh retry is
    /// scheduled and cleared when any refresh succeeds.
    private var pendingPostRefreshRetry = false

    let notificationManager = NotificationManager()
    private let client = UsageAPIClient()
    private var pollTask: Task<Void, Never>?

    /// In-memory credential cache. Reading credentials launches a
    /// `/usr/bin/security` subprocess, so we avoid doing it on every
    /// poll cycle. The cache is invalidated when the token expires or
    /// the API rejects it, reducing subprocess invocations to at most
    /// once per token rotation (~2–3×/day).
    private var cachedCredentials: ClaudeCredentials?

    /// Allowed user-configurable range for the poll interval, in seconds.
    /// Anchored at 5 minutes (the default) and floored at 2 minutes — any
    /// lower and we'd start tripping the endpoint's rate limiter again.
    private static let minPollIntervalSeconds = 120
    private static let maxPollIntervalSeconds = 300

    /// How often the store refreshes in the background. Read fresh from
    /// `UserDefaults` on every tick so a change from the Settings window
    /// applies on the next scheduled iteration without any observers.
    /// `/api/oauth/usage` is an undocumented endpoint with an aggressive
    /// rate limiter — see anthropics/claude-code#31021.
    private var pollInterval: Duration {
        let stored = UserDefaults.standard.integer(forKey: SettingsKeys.pollIntervalSeconds)
        let clamped: Int
        if stored >= Self.minPollIntervalSeconds && stored <= Self.maxPollIntervalSeconds {
            clamped = stored
        } else {
            clamped = defaultPollIntervalSeconds
        }
        return .seconds(clamped)
    }

    /// Minimum time between successful fetches when the popover is opened.
    /// Protects the undocumented endpoint from rapid popover open/close
    /// patterns — if a successful fetch happened within this window, we
    /// show the existing snapshot instead of firing another request.
    private let popoverDebounceInterval: TimeInterval = 15

    /// Fallback backoff when the server doesn't provide a `Retry-After`.
    /// The `/api/oauth/usage` endpoint is known to return persistent 429s
    /// (see anthropics/claude-code#31021), so we're generous here.
    private let defaultRateLimitBackoff: TimeInterval = 300 // 5 minutes

    /// Minimum cooldown we'll ever observe after a 429, regardless of what
    /// the server suggests. Prevents a stray `Retry-After: 0` (or a past
    /// HTTP-date) from effectively disabling the cooldown and letting the
    /// background poll hammer the endpoint once per minute.
    private let minRateLimitBackoff: TimeInterval = 60

    /// Returns cached credentials when they're still valid, otherwise
    /// reads fresh credentials from the Keychain (which may trigger a
    /// macOS authorization prompt).
    private func loadCredentials() throws -> ClaudeCredentials {
        if let cached = cachedCredentials, !cached.isExpired {
            DiagnosticLog.shared.log(.keychain, "Using cached credentials")
            return cached
        }
        DiagnosticLog.shared.log(.keychain, "Cache miss, loading from Keychain")
        let fresh = try KeychainCredentialStore.load()
        cachedCredentials = fresh
        keychainReadMethod = KeychainCredentialStore.lastReadMethod
        return fresh
    }

    // MARK: Lifecycle

    /// Starts the background poll loop. Safe to call repeatedly — a second
    /// call while polling is already active is a no-op.
    func startPolling() {
        guard pollTask == nil else { return }
        notificationManager.registerAsDelegate()
        notificationManager.reauthenticateHandler = { [weak self] in
            self?.manualRetry()
        }
        Task { await notificationManager.refreshAuthorizationStatus() }
        CredentialRefresher.onRefreshEnded = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // credentialsBecameValid() also calls onRefreshEnded,
                // but that fires during a normal successful fetch —
                // not after a background claude process. Only retry
                // when a real background process just finished.
                let wasRefreshingInBackground = self.isRefreshingCredentials
                self.isRefreshingCredentials = false
                guard wasRefreshingInBackground else { return }
                self.cachedCredentials = nil
                guard !self.pendingPostRefreshRetry else { return }
                self.pendingPostRefreshRetry = true
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    await self?.refresh()
                }
            }
        }
        pollTask = makePollTask(fetchImmediately: true)
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Cancels the currently running poll task and starts a new one with
    /// whatever `pollInterval` currently resolves to. Used by the Settings
    /// window when the user changes the interval so the new cadence takes
    /// effect immediately instead of after the existing sleep finishes.
    /// Does **not** fire an extra refresh — the loop simply begins its
    /// first sleep at the new duration.
    func reschedulePolling() {
        guard pollTask != nil else { return }
        stopPolling()
        pollTask = makePollTask(fetchImmediately: false)
    }

    /// Called when the user opens the popover. Fires a one-off debounced
    /// refresh so the bars are fresh on screen, but doesn't restart the
    /// poll loop — the background poll continues on its own schedule
    /// regardless.
    func refreshNow() {
        Task { @MainActor [weak self] in
            await self?.refresh(minIntervalSinceLastSuccess: self?.popoverDebounceInterval ?? 0)
        }
    }

    /// Called when the user explicitly asks for another attempt: the
    /// popover's "Try again" button, or the auth-lost notification's
    /// "Reauthenticate" action. Drops the credential cache and clears the
    /// post-refresh retry guard, then refreshes — which re-reads the
    /// Keychain (picking up a token some other Claude Code process may
    /// already have rotated) and only launches `claude` if the token is
    /// genuinely expired. Without the guard resets, the background poll's
    /// deduplication would leave the user stuck on a "Run `claude` to
    /// re-authenticate" message with no recourse.
    ///
    /// The launch-deduplication guard is reset only when no background
    /// `claude` is running. The popover hides "Try again" during a
    /// refresh, but the notification action can arrive mid-refresh, and
    /// resetting the guard there would only start a second `claude`
    /// alongside the first. Left alone, its exit triggers the post-refresh
    /// retry, which the cleared `pendingPostRefreshRetry` now permits.
    func manualRetry() {
        cachedCredentials = nil
        pendingPostRefreshRetry = false
        if !isRefreshingCredentials {
            CredentialRefresher.resetAttemptGuard()
        }
        Task { @MainActor [weak self] in
            await self?.refresh()
        }
    }

    /// Wipes the diagnostic counters and resets the measurement window to
    /// `now`. Used by the Developer tab's Reset button so the user can
    /// benchmark the fetch rate from a fresh baseline.
    func resetDiagnostics() {
        networkRequestCount = 0
        lastNetworkAttemptAt = nil
        diagnosticsStartedAt = Date()
    }

    /// Builds the poll task body. If `fetchImmediately` is false the loop
    /// sleeps first and then refreshes, which is what `reschedulePolling()`
    /// wants: the user just changed the cadence, we don't need to fetch
    /// again right now, we just need to respect the new sleep duration.
    private func makePollTask(fetchImmediately: Bool) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            var shouldFetch = fetchImmediately
            while !Task.isCancelled {
                if shouldFetch {
                    await self.refresh()
                }
                shouldFetch = true
                try? await Task.sleep(for: self.pollInterval)
            }
        }
    }

    // MARK: Refresh

    /// Fetches the usage endpoint and updates `state`.
    ///
    /// - Parameter minIntervalSinceLastSuccess: If greater than zero and the
    ///   last successful fetch happened within this many seconds, the call
    ///   is a no-op. Lets the popover-open path avoid hitting the server
    ///   when the background poll just refreshed.
    func refresh(minIntervalSinceLastSuccess: TimeInterval = 0) async {
        // Re-entrancy guard: if a refresh is already in flight, don't fire
        // a second one. The background poll and the popover both call this,
        // and back-to-back requests are exactly what trips the 429 limiter.
        guard !isRefreshing else { return }

        // Debounce rapid popover opens against the most recent success.
        if minIntervalSinceLastSuccess > 0,
           let lastUpdated,
           Date().timeIntervalSince(lastUpdated) < minIntervalSinceLastSuccess {
            return
        }

        // Respect any active rate-limit cooldown from a previous 429.
        if let rateLimitedUntil, Date() < rateLimitedUntil {
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        let credentials: ClaudeCredentials
        do {
            credentials = try loadCredentials()
        } catch KeychainError.itemNotFound {
            cachedCredentials = nil
            state = .missingCredentials
            notificationManager.notifyAuthenticationLost()
            return
        } catch {
            cachedCredentials = nil
            state = .error(error.localizedDescription)
            return
        }

        // Bail early if the access token has expired — there's no point
        // hitting the API with a dead token. Instead, launch Claude Code
        // in the background so it can use the refresh token (or prompt
        // for interactive login) and write fresh credentials to the
        // Keychain. The background poll will pick them up automatically.
        if credentials.isExpired {
            cachedCredentials = nil
            DiagnosticLog.shared.log(.refresh, "Token expired, attempting background refresh")
            handleAuthenticationLost(reason: "Your Claude Code token has expired.")
            return
        }

        // Surface a spinner only on the first load — subsequent refreshes
        // keep the previous snapshot visible so the bars don't flicker.
        if case .loaded = state {
            // keep snapshot, just toggle isRefreshing
        } else {
            state = .loading
        }

        await fetchUsage(using: credentials, retryOnRotation: true)
    }

    /// Performs one request against the usage endpoint and applies the
    /// outcome to `state`.
    ///
    /// - Parameter retryOnRotation: When `true`, a 401/403 is first treated
    ///   as a possible token rotation rather than a lost login: the
    ///   credential cache is dropped, the Keychain re-read, and if it now
    ///   holds a different, unexpired token the request is retried once
    ///   with it — silently, with no notification and no background
    ///   `claude` launch. Claude Code rotates the access token whenever it
    ///   refreshes and the previous token is rejected immediately, so a
    ///   401 on a cached token usually means another Claude Code process
    ///   (typically the user's terminal session) already did the work.
    ///   The diagnostic log showed nearly every "Authentication Lost"
    ///   notification was this case.
    private func fetchUsage(using credentials: ClaudeCredentials, retryOnRotation: Bool) async {
        // Count this as a real network attempt. Placed after all the
        // early-return guards so the counter only reflects requests that
        // actually hit the wire — the Developer tab uses this to verify
        // the app isn't spamming the endpoint.
        networkRequestCount += 1
        lastNetworkAttemptAt = Date()
        DiagnosticLog.shared.log(.api, "Request #\(networkRequestCount) started")

        do {
            let response = try await client.fetch(using: credentials)
            DiagnosticLog.shared.log(.api, "HTTP 200 — usage data received")
            CredentialRefresher.credentialsBecameValid()
            pendingPostRefreshRetry = false
            notificationManager.authenticationRestored()
            let snapshot = Self.buildSnapshot(from: response)
            state = .loaded(snapshot)
            lastUpdated = snapshot.fetchedAt
            rateLimitedUntil = nil
            notificationManager.evaluateThresholds(snapshot: snapshot)
        } catch UsageAPIError.rateLimited(let retryAfter) {
            // Respect the server's hint if it's sensible, but never drop
            // below our own minimum — a `Retry-After: 0` header must not
            // translate to "no cooldown".
            let suggested = retryAfter ?? defaultRateLimitBackoff
            let backoff = max(suggested, minRateLimitBackoff)
            DiagnosticLog.shared.log(.api, "HTTP 429 — rate limited, backoff \(Int(backoff))s")
            rateLimitedUntil = Date().addingTimeInterval(backoff)
            // If we already had a good snapshot, keep it visible rather than
            // replacing the bars with an error screen — the data is stale
            // but still the most useful thing we can show the user.
            if case .loaded = state { return }
            state = .error(UsageAPIError.rateLimited(retryAfter: backoff).errorDescription ?? "Rate limited.")
        } catch UsageAPIError.credentialExpired {
            // Safety net — the early `isExpired` check in `refresh()` should
            // catch this, but a narrow race between the check and the fetch
            // call could let a just-expired token slip through.
            DiagnosticLog.shared.log(.api, "Credential expired during fetch")
            cachedCredentials = nil
            handleAuthenticationLost(reason: "Your Claude Code token has expired.")
        } catch UsageAPIError.unauthorized {
            DiagnosticLog.shared.log(.api, "HTTP 401/403 — token rejected")
            cachedCredentials = nil
            if retryOnRotation,
               let rotated = Self.rotatedCredentials(replacing: credentials, reloaded: try? loadCredentials()) {
                DiagnosticLog.shared.log(.keychain, "Keychain holds a newer token — retrying silently")
                await fetchUsage(using: rotated, retryOnRotation: false)
                return
            }
            // The Keychain has nothing better to offer, so the token really
            // was revoked or invalidated — running `claude` re-authenticates.
            handleAuthenticationLost(reason: "Claude rejected the stored token.")
        } catch let error as UsageAPIError {
            DiagnosticLog.shared.log(.api, "API error: \(error.errorDescription ?? "unknown")")
            state = .error(error.errorDescription ?? "Unknown usage API error.")
        } catch {
            DiagnosticLog.shared.log(.api, "Error: \(error.localizedDescription)")
            state = .error(error.localizedDescription)
        }
    }

    /// Decides whether a rejected token should be retried with credentials
    /// re-read from the Keychain. Returns the reloaded credentials when they
    /// carry a different, unexpired access token; `nil` when the re-read
    /// failed, returned the same token (no rotation happened), or returned
    /// a token that is itself expired — that case needs the background
    /// `claude` refresh, not another request.
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

    /// Shared tail of every authentication-loss path: fire the one-shot
    /// notification, launch the background `claude` refresh (a no-op when
    /// one is already running), and set an error state whose wording
    /// reflects whether a refresh is actually in progress — including one
    /// that was already running before this call, which is what happens
    /// when the popover opens or the notification is tapped mid-refresh.
    private func handleAuthenticationLost(reason: String) {
        notificationManager.notifyAuthenticationLost()
        if CredentialRefresher.refreshInBackground() {
            isRefreshingCredentials = true
        }
        state = .error(isRefreshingCredentials
            ? "\(reason) Refreshing in the background…"
            : "\(reason) Run `claude` to re-authenticate.")
    }
}
