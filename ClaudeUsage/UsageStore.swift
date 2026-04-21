//
//  UsageStore.swift
//  Menu Bar Usage for Claude
//
//  Fetches the undocumented `/api/oauth/usage` endpoint that Claude Code uses
//  for the three progress bars in its status line.
//

import Foundation
import Observation

// MARK: - Wire format

/// A single utilisation window returned by `/api/oauth/usage`.
/// `utilization` is a percentage (0…100) and may be nil if the window isn't
/// applicable to this account (e.g. `seven_day_opus` for non-Max users).
struct UsageWindow: Decodable, Sendable {
    let utilization: Double?
    let resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

/// The `extra_usage` object returned by the usage endpoint. All fields
/// other than `isEnabled` are `nil` when the user hasn't turned Extra
/// Usage on in their claude.ai account.
struct ExtraUsageResponse: Decodable, Sendable {
    let isEnabled: Bool
    let monthlyLimit: Double?
    let usedCredits: Double?
    let utilization: Double?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
    }
}

/// The full response from `GET https://api.anthropic.com/api/oauth/usage`.
/// Only the fields we actually render are modelled.
struct UsageResponse: Decodable, Sendable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDayOpus: UsageWindow?
    let sevenDaySonnet: UsageWindow?
    let extraUsage: ExtraUsageResponse?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
    }
}

// MARK: - Display snapshot

/// The data the popover actually renders, derived from a `UsageResponse`.
struct UsageSnapshot: Sendable {
    var session: Bar
    var weekly: Bar
    var sonnet: Bar?
    var extraUsage: ExtraUsageSummary?
    var fetchedAt: Date

    /// The highest utilisation across the quota bars (session/weekly/sonnet),
    /// used to tint the status bar icon. Extra Usage is deliberately
    /// excluded: it represents paid overflow, not remaining free quota,
    /// so mixing it into the "peak" would send the wrong signal.
    var peakUtilization: Double {
        let bars = [session, weekly, sonnet].compactMap { $0 }
        return bars.map(\.fraction).max() ?? 0
    }

    struct Bar: Sendable, Identifiable {
        let id: Kind
        let title: String
        /// 0…1 fraction used to fill the progress bar.
        let fraction: Double
        /// Pre-formatted percentage label (e.g. "12%").
        let percentLabel: String
        let resetsAt: Date?

        enum Kind: String, Sendable {
            case session
            case weekly
            case sonnet
        }
    }

    /// Everything the Extra Usage card needs to render. Nil when the user
    /// hasn't enabled Extra Usage on their claude.ai account, or when the
    /// API returned an enabled flag but with null numbers.
    struct ExtraUsageSummary: Sendable {
        /// 0…1 fraction of the monthly limit consumed.
        let fraction: Double
        /// Pre-formatted percentage label (e.g. "38%").
        let percentLabel: String
        /// Credits consumed this month.
        let used: Double
        /// Credits available this month (the user-set monthly limit).
        let monthlyLimit: Double
        /// Credits remaining, i.e. `monthlyLimit - used`, clamped at zero.
        var remaining: Double { max(0, monthlyLimit - used) }
    }
}

// MARK: - API client

enum UsageAPIError: LocalizedError {
    case credentialExpired
    case unauthorized
    /// The endpoint returned HTTP 429. The associated value is the
    /// server-suggested retry delay in seconds (from `Retry-After`), or
    /// `nil` if the header was absent or unparsable.
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case transport(Error)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .credentialExpired:
            return "Your Claude Code token has expired. Open Claude Code to refresh it."
        case .unauthorized:
            return "Claude rejected the stored token. Run `claude` to re-authenticate."
        case .rateLimited:
            // Deliberately vague — the popover renders a live countdown
            // sourced from `UsageStore.rateLimitedUntil`, which is always
            // more accurate than a static string baked in at error time.
            return "Claude’s usage endpoint is rate-limiting us."
        case .http(let code):
            return "Claude’s usage endpoint returned HTTP \(code)."
        case .transport(let error):
            return "Network error: \(error.localizedDescription)"
        case .decoding:
            return "Couldn’t decode the usage response from Claude."
        }
    }
}

struct UsageAPIClient {
    /// The undocumented endpoint that Claude Code itself calls for status-line data.
    /// This is not a public API and may change without notice.
    var endpoint: URL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    var session: URLSession = .shared

    func fetch(using credentials: ClaudeCredentials) async throws -> UsageResponse {
        if credentials.isExpired {
            throw UsageAPIError.credentialExpired
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("MenuBarUsageForClaude/1.0 (macOS menu bar)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageAPIError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UsageAPIError.http(-1)
        }

        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw UsageAPIError.unauthorized
        case 429:
            let retryAfter = Self.parseRetryAfter(http.value(forHTTPHeaderField: "Retry-After"))
            throw UsageAPIError.rateLimited(retryAfter: retryAfter)
        default:
            throw UsageAPIError.http(http.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
        do {
            return try decoder.decode(UsageResponse.self, from: data)
        } catch {
            throw UsageAPIError.decoding(error)
        }
    }

    /// Parses a `Retry-After` header value. Supports the integer-seconds form
    /// (e.g. "120"); the HTTP-date form is rare in practice for 429 and we
    /// fall back to a default backoff if we can't make sense of it.
    ///
    /// Returns `nil` (rather than zero) for any value strictly less than
    /// one second — a `Retry-After: 0` header or an HTTP-date in the past
    /// isn't a useful cooldown hint, so we'd rather fall back to the
    /// store's default backoff than respect a zero.
    private static func parseRetryAfter(_ value: String?) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(value), seconds >= 1 {
            return seconds
        }
        // HTTP-date form: "Wed, 21 Oct 2026 07:28:00 GMT"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: value) {
            let interval = date.timeIntervalSinceNow
            return interval >= 1 ? interval : nil
        }
        return nil
    }
}

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
        Task { await notificationManager.refreshAuthorizationStatus() }
        CredentialRefresher.onRefreshEnded = { [weak self] in
            MainActor.assumeIsolated {
                self?.isRefreshingCredentials = false
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

    /// Called when the user explicitly clicks "Try again" or the manual
    /// refresh button. Resets the credential-refresh deduplication guard
    /// before refreshing so a new background `claude` process can be
    /// launched if a prior auto-refresh attempt failed silently — the
    /// background poll's guard would otherwise leave the user stuck on
    /// a "Run `claude` to re-authenticate" message with no recourse.
    func manualRetry() {
        CredentialRefresher.resetAttemptGuard()
        cachedCredentials = nil
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
            notificationManager.notifyAuthenticationLost()
            let started = CredentialRefresher.refreshInBackground()
            if started { isRefreshingCredentials = true }
            state = .error(started
                ? "Your Claude Code token has expired. Refreshing in the background…"
                : "Your Claude Code token has expired. Run `claude` to re-authenticate.")
            return
        }

        // Surface a spinner only on the first load — subsequent refreshes
        // keep the previous snapshot visible so the bars don't flicker.
        if case .loaded = state {
            // keep snapshot, just toggle isRefreshing
        } else {
            state = .loading
        }

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
            notificationManager.authenticationRestored()
            let snapshot = Self.buildSnapshot(from: response, credentials: credentials)
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
            // Safety net — the early `isExpired` check above should catch
            // this, but a narrow race between the check and the fetch call
            // could let a just-expired token slip through.
            DiagnosticLog.shared.log(.api, "Credential expired during fetch")
            cachedCredentials = nil
            notificationManager.notifyAuthenticationLost()
            let started = CredentialRefresher.refreshInBackground()
            if started { isRefreshingCredentials = true }
            state = .error(started
                ? "Your Claude Code token has expired. Refreshing in the background…"
                : "Your Claude Code token has expired. Run `claude` to re-authenticate.")
        } catch UsageAPIError.unauthorized {
            // The server rejected the token (401/403). This usually means
            // the token was revoked or is otherwise invalid — running
            // `claude` will re-authenticate.
            DiagnosticLog.shared.log(.api, "HTTP 401/403 — token rejected")
            cachedCredentials = nil
            notificationManager.notifyAuthenticationLost()
            let started = CredentialRefresher.refreshInBackground()
            if started { isRefreshingCredentials = true }
            state = .error(started
                ? "Claude rejected the stored token. Refreshing in the background…"
                : "Claude rejected the stored token. Run `claude` to re-authenticate.")
        } catch let error as UsageAPIError {
            DiagnosticLog.shared.log(.api, "API error: \(error.errorDescription ?? "unknown")")
            state = .error(error.errorDescription ?? "Unknown usage API error.")
        } catch {
            DiagnosticLog.shared.log(.api, "Error: \(error.localizedDescription)")
            state = .error(error.localizedDescription)
        }
    }

    // MARK: Snapshot builder

    private static func buildSnapshot(
        from response: UsageResponse,
        credentials: ClaudeCredentials
    ) -> UsageSnapshot {
        let session = bar(
            kind: .session,
            title: "Current Session",
            window: response.fiveHour
        )
        let weekly = bar(
            kind: .weekly,
            title: "Weekly Limit",
            window: response.sevenDay
        )

        // The Sonnet bar is Max-only in Claude Desktop/Code. We hide it if:
        //   • the user isn't on Max, OR
        //   • the API returned null for that window.
        let sonnet: UsageSnapshot.Bar?
        if credentials.isMaxSubscription, let window = response.sevenDaySonnet {
            sonnet = bar(kind: .sonnet, title: "Sonnet", window: window)
        } else {
            sonnet = nil
        }

        // The Extra Usage card only appears if the account has actually
        // enabled paid overflow in claude.ai settings — in which case the
        // endpoint returns populated numbers. If anything required is
        // missing we treat it as "not enabled" and hide the card.
        let extraUsage: UsageSnapshot.ExtraUsageSummary?
        if let e = response.extraUsage,
           e.isEnabled,
           let limit = e.monthlyLimit, limit > 0,
           let used = e.usedCredits,
           let util = e.utilization {
            let fraction = min(max(util / 100.0, 0), 1)
            extraUsage = UsageSnapshot.ExtraUsageSummary(
                fraction: fraction,
                percentLabel: Self.percentFormatter.string(from: NSNumber(value: fraction)) ?? "0%",
                used: used,
                monthlyLimit: limit
            )
        } else {
            extraUsage = nil
        }

        return UsageSnapshot(
            session: session,
            weekly: weekly,
            sonnet: sonnet,
            extraUsage: extraUsage,
            fetchedAt: Date()
        )
    }

    private static func bar(
        kind: UsageSnapshot.Bar.Kind,
        title: String,
        window: UsageWindow?
    ) -> UsageSnapshot.Bar {
        let raw = window?.utilization ?? 0
        let fraction = min(max(raw / 100.0, 0), 1)
        return UsageSnapshot.Bar(
            id: kind,
            title: title,
            fraction: fraction,
            percentLabel: Self.percentFormatter.string(from: NSNumber(value: fraction)) ?? "0%",
            resetsAt: window?.resetsAt
        )
    }

    private static let percentFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .percent
        f.maximumFractionDigits = 0
        return f
    }()
}

// MARK: - ISO-8601 with fractional seconds

private extension JSONDecoder.DateDecodingStrategy {
    /// The usage endpoint returns timestamps like `2026-04-11T18:00:01.219127+00:00`,
    /// which the default `.iso8601` strategy rejects because of the microseconds.
    static var iso8601WithFractionalSeconds: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)

            let withFractional = ISO8601DateFormatter()
            withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFractional.date(from: string) {
                return date
            }

            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: string) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected ISO-8601 date, got \(string)"
            )
        }
    }
}
