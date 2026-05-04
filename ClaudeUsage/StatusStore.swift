//
//  StatusStore.swift
//  Menu Bar Usage for Claude
//
//  Polls https://status.claude.com/api/v2/summary.json (Atlassian Statuspage)
//  to surface the current operational state of Claude services. Triggered
//  only when the popover is opened — no background polling.
//

import Foundation
import Observation

// MARK: - Known components

/// The set of components Statuspage exposes for status.claude.com. IDs are
/// stable Atlassian-issued identifiers that don't change when component
/// names are edited, so user preferences key off them rather than off the
/// human-readable name.
///
/// When Anthropic adds a new service to the status page, append a case
/// here — `defaultEnabled` decides whether it's opt-in or opt-out.
enum KnownComponent: String, CaseIterable, Identifiable, Sendable {
    case claudeAI       = "rwppv331jlwc"
    case claudeCode     = "yyzkbfz2thpt"
    case claudeAPI      = "k8w3r06qmzrp"
    case claudeConsole  = "0qbwn08sd68x"
    case claudeCowork   = "bpp5gb3hpjcl"
    case claudeForGov   = "0scnb50nvy53"

    var id: String { rawValue }

    /// Display name as it appears on status.claude.com.
    var displayName: String {
        switch self {
        case .claudeAI:      return "claude.ai"
        case .claudeCode:    return "Claude Code"
        case .claudeAPI:     return "Claude API"
        case .claudeConsole: return "Claude Console"
        case .claudeCowork:  return "Claude Cowork"
        case .claudeForGov:  return "Claude for Government"
        }
    }

    /// UserDefaults key that stores whether the user is monitoring this
    /// component. Read/written by `@AppStorage` in Settings and by
    /// `StatusStore` when filtering the response.
    var settingsKey: String {
        switch self {
        case .claudeAI:      return SettingsKeys.monitorClaudeAI
        case .claudeCode:    return SettingsKeys.monitorClaudeCode
        case .claudeAPI:     return SettingsKeys.monitorClaudeAPI
        case .claudeConsole: return SettingsKeys.monitorClaudeConsole
        case .claudeCowork:  return SettingsKeys.monitorClaudeCowork
        case .claudeForGov:  return SettingsKeys.monitorClaudeForGov
        }
    }

    /// Default monitoring state per component. claude.ai and Claude Code
    /// are on by default — everything else is opt-in.
    var defaultEnabled: Bool {
        switch self {
        case .claudeAI, .claudeCode: return true
        default: return false
        }
    }

    /// Returns the user's current monitoring choice, falling back to the
    /// component's default when nothing's been written to UserDefaults yet.
    static func isMonitored(_ component: KnownComponent) -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: component.settingsKey) == nil {
            return component.defaultEnabled
        }
        return defaults.bool(forKey: component.settingsKey)
    }
}

// MARK: - Severity

/// Severity ordering used by Atlassian Statuspage for both page-level
/// indicators and per-component statuses, mapped onto a single enum so we
/// can compute "what's the worst thing happening right now?" with `max()`.
enum StatusSeverity: Int, Comparable, Sendable {
    case operational = 0
    case maintenance = 1
    case minor       = 2  // degraded_performance
    case major       = 3  // partial_outage
    case critical    = 4  // major_outage

    static func < (lhs: StatusSeverity, rhs: StatusSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Maps a Statuspage `component.status` string onto our severity
    /// scale. Unknown values are treated as `.operational` so a future
    /// status-string addition doesn't false-alarm the user.
    static func fromComponentStatus(_ raw: String) -> StatusSeverity {
        switch raw {
        case "operational":           return .operational
        case "under_maintenance":     return .maintenance
        case "degraded_performance":  return .minor
        case "partial_outage":        return .major
        case "major_outage":          return .critical
        default:                      return .operational
        }
    }

    /// User-facing label for per-component severity, used as the caption
    /// on each affected-component line.
    var componentLabel: String {
        switch self {
        case .operational: return "Operational"
        case .maintenance: return "Under Maintenance"
        case .minor:       return "Degraded Performance"
        case .major:       return "Partial Outage"
        case .critical:    return "Major Outage"
        }
    }
}

// MARK: - Wire format

struct StatusResponse: Decodable, Sendable {
    struct Indicator: Decodable, Sendable {
        let indicator: String
        let description: String
    }
    struct Component: Decodable, Sendable {
        let id: String
        let name: String
        let status: String
    }
    struct Incident: Decodable, Sendable {
        let id: String
        let name: String
        let status: String
        let shortlink: String?
        let components: [Component]?
    }

    let status: Indicator
    let components: [Component]
    let incidents: [Incident]
}

// MARK: - Display snapshot

/// The data the popover's status row renders. `StatusStore` builds one of
/// these on every successful fetch, applying the user's monitored-components
/// filter so the view layer doesn't have to.
struct StatusSnapshot: Sendable {
    /// Worst severity across the user's monitored components.
    /// `.operational` when nothing they care about is degraded.
    let displaySeverity: StatusSeverity
    /// Page-level human description from the API, e.g. "All Systems
    /// Operational" or "Partial System Outage". The view chooses whether
    /// to surface this or a locally-derived label.
    let pageDescription: String
    /// Non-operational components from the user's monitored set, worst
    /// severity first.
    let affectedComponents: [AffectedComponent]
    /// Active incidents whose `components` array overlaps the monitored
    /// set (or is empty/missing, which we treat as page-wide).
    let relevantIncidents: [Incident]
    let fetchedAt: Date

    struct AffectedComponent: Sendable, Identifiable {
        let id: String
        let name: String
        let severity: StatusSeverity
    }

    struct Incident: Sendable, Identifiable {
        let id: String
        let name: String
        let url: URL?
    }
}

// MARK: - API client

enum StatusAPIError: LocalizedError {
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case transport(Error)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .rateLimited:
            return "status.claude.com is rate-limiting us."
        case .http(let code):
            return "status.claude.com returned HTTP \(code)."
        case .transport(let error):
            return "Network error: \(error.localizedDescription)"
        case .decoding:
            return "Couldn’t decode the status response."
        }
    }
}

struct StatusAPIClient {
    var endpoint: URL = URL(string: "https://status.claude.com/api/v2/summary.json")!
    var session: URLSession = .shared

    func fetch() async throws -> StatusResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("MenuBarUsageForClaude/1.0 (macOS menu bar)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw StatusAPIError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw StatusAPIError.http(-1)
        }

        switch http.statusCode {
        case 200:
            break
        case 429:
            let retryAfter = Self.parseRetryAfter(http.value(forHTTPHeaderField: "Retry-After"))
            throw StatusAPIError.rateLimited(retryAfter: retryAfter)
        default:
            throw StatusAPIError.http(http.statusCode)
        }

        do {
            return try JSONDecoder().decode(StatusResponse.self, from: data)
        } catch {
            throw StatusAPIError.decoding(error)
        }
    }

    /// Mirrors `UsageAPIClient.parseRetryAfter` — supports the
    /// integer-seconds form and the rare HTTP-date form, with anything
    /// less than one second collapsed to nil so a stray `Retry-After: 0`
    /// can't disable the cooldown.
    private static func parseRetryAfter(_ value: String?) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(value), seconds >= 1 {
            return seconds
        }
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

/// Owns the status snapshot rendered by `ServiceStatusRow`. Only fetches
/// when the popover is opened and the cached snapshot is older than
/// `refreshTTL`. No background polling, no notifications.
@Observable
@MainActor
final class StatusStore {
    enum State {
        case idle
        case loading
        case loaded(StatusSnapshot)
        case error(String)
    }

    private(set) var state: State = .idle
    private(set) var lastUpdated: Date?
    private(set) var rateLimitedUntil: Date?

    private let client = StatusAPIClient()
    private var inFlight = false

    /// How long a successful fetch is considered fresh. Popover-open
    /// triggers within this window are no-ops.
    private let refreshTTL: TimeInterval = 300  // 5 minutes

    /// Fallback backoff when a 429 response arrives without a parsable
    /// `Retry-After`. Generous because Statuspage is a public CDN and
    /// 429s are rare — when we do hit one, something unusual is happening.
    private let defaultRateLimitBackoff: TimeInterval = 600  // 10 minutes

    /// Floor on any 429 cooldown — protects against `Retry-After: 0`
    /// headers that would otherwise effectively disable the cooldown.
    private let minRateLimitBackoff: TimeInterval = 60

    /// Returns true when the global service-status feature toggle is on.
    /// Defaults to `true` until the user explicitly turns it off.
    private static func isFeatureEnabled() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: SettingsKeys.serviceStatusEnabled) == nil {
            return true
        }
        return defaults.bool(forKey: SettingsKeys.serviceStatusEnabled)
    }

    private static func anyComponentMonitored() -> Bool {
        KnownComponent.allCases.contains(where: KnownComponent.isMonitored)
    }

    /// Fetches the status summary if enough time has passed since the
    /// last successful fetch. No-op when the feature is off, no
    /// components are monitored, a fetch is already in flight, or the
    /// cached snapshot is still within `refreshTTL`.
    func refreshIfStale() async {
        guard Self.isFeatureEnabled() else { return }
        guard Self.anyComponentMonitored() else { return }
        if let lastUpdated, Date().timeIntervalSince(lastUpdated) < refreshTTL {
            return
        }
        await refresh()
    }

    private func refresh() async {
        guard !inFlight else { return }
        if let rateLimitedUntil, Date() < rateLimitedUntil { return }

        inFlight = true
        defer { inFlight = false }

        if case .loaded = state {
            // Keep the existing snapshot visible while refetching.
        } else {
            state = .loading
        }

        DiagnosticLog.shared.log(.status, "Fetching status.claude.com")

        do {
            let response = try await client.fetch()
            DiagnosticLog.shared.log(.status, "HTTP 200 — page indicator: \(response.status.indicator)")
            let snapshot = Self.buildSnapshot(from: response)
            state = .loaded(snapshot)
            lastUpdated = snapshot.fetchedAt
            rateLimitedUntil = nil
        } catch StatusAPIError.rateLimited(let retryAfter) {
            let suggested = retryAfter ?? defaultRateLimitBackoff
            let backoff = max(suggested, minRateLimitBackoff)
            DiagnosticLog.shared.log(.status, "HTTP 429 — backoff \(Int(backoff))s")
            rateLimitedUntil = Date().addingTimeInterval(backoff)
            if case .loaded = state { return }
            state = .error(StatusAPIError.rateLimited(retryAfter: backoff).errorDescription ?? "Rate limited.")
        } catch let error as StatusAPIError {
            DiagnosticLog.shared.log(.status, "Error: \(error.errorDescription ?? "unknown")")
            state = .error(error.errorDescription ?? "Unknown status API error.")
        } catch {
            DiagnosticLog.shared.log(.status, "Error: \(error.localizedDescription)")
            state = .error(error.localizedDescription)
        }
    }

    // MARK: Snapshot derivation

    private static func buildSnapshot(from response: StatusResponse) -> StatusSnapshot {
        let monitoredIDs = Set(
            KnownComponent.allCases
                .filter(KnownComponent.isMonitored)
                .map(\.rawValue)
        )

        let affected: [StatusSnapshot.AffectedComponent] = response.components
            .filter { monitoredIDs.contains($0.id) }
            .map { component in
                StatusSnapshot.AffectedComponent(
                    id: component.id,
                    name: component.name,
                    severity: StatusSeverity.fromComponentStatus(component.status)
                )
            }
            .filter { $0.severity != .operational }
            .sorted { $0.severity > $1.severity }  // worst first

        let displaySeverity = affected.map(\.severity).max() ?? .operational

        let relevantIncidents: [StatusSnapshot.Incident] = response.incidents
            .filter { incident in
                // Page-wide incidents (no components attached) are always
                // shown; component-tagged incidents only when they overlap
                // the user's monitored set.
                guard let comps = incident.components, !comps.isEmpty else { return true }
                return comps.contains { monitoredIDs.contains($0.id) }
            }
            .map { incident in
                StatusSnapshot.Incident(
                    id: incident.id,
                    name: incident.name,
                    url: incident.shortlink.flatMap { URL(string: $0) }
                )
            }

        return StatusSnapshot(
            displaySeverity: displaySeverity,
            pageDescription: response.status.description,
            affectedComponents: affected,
            relevantIncidents: relevantIncidents,
            fetchedAt: Date()
        )
    }
}
