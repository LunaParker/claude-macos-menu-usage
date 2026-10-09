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
/// When Anthropic adds a new service to the status page, append a case here
/// and give it a display name and a preference key; Settings lists every case.
nonisolated enum KnownComponent: String, CaseIterable, Identifiable, Sendable {
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

    /// Whether the user monitors this component. claude.ai and Claude Code
    /// are on by default; everything else is opt-in.
    var setting: SettingKey<Bool> {
        switch self {
        case .claudeAI:      return SettingKey(name: "monitorClaudeAI", defaultValue: true)
        case .claudeCode:    return SettingKey(name: "monitorClaudeCode", defaultValue: true)
        case .claudeAPI:     return SettingKey(name: "monitorClaudeAPI", defaultValue: false)
        case .claudeConsole: return SettingKey(name: "monitorClaudeConsole", defaultValue: false)
        case .claudeCowork:  return SettingKey(name: "monitorClaudeCowork", defaultValue: false)
        case .claudeForGov:  return SettingKey(name: "monitorClaudeForGov", defaultValue: false)
        }
    }

    static func monitored(in defaults: UserDefaults) -> Set<KnownComponent> {
        Set(allCases.filter { defaults[$0.setting] })
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

/// The data the popover's status row renders: a status response filtered to
/// the components the user monitors.
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

extension StatusSnapshot {
    init(response: StatusResponse, monitored: Set<KnownComponent>, fetchedAt: Date) {
        let monitoredIDs = Set(monitored.map(\.rawValue))

        let affected: [AffectedComponent] = response.components
            .filter { monitoredIDs.contains($0.id) }
            .map { AffectedComponent(id: $0.id, name: $0.name, severity: StatusSeverity.fromComponentStatus($0.status)) }
            .filter { $0.severity != .operational }
            .sorted { $0.severity > $1.severity }

        // Incidents with no components attached are page-wide and always shown.
        let incidents: [Incident] = response.incidents
            .filter { incident in
                guard let components = incident.components, !components.isEmpty else { return true }
                return components.contains { monitoredIDs.contains($0.id) }
            }
            .map { Incident(id: $0.id, name: $0.name, url: $0.shortlink.flatMap { URL(string: $0) }) }

        self.init(
            displaySeverity: affected.map(\.severity).max() ?? .operational,
            pageDescription: response.status.description,
            affectedComponents: affected,
            relevantIncidents: incidents,
            fetchedAt: fetchedAt
        )
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
    var http: HTTPClient = .shared

    func fetch() async throws -> StatusResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http.send(request)
        } catch {
            switch error {
            case .transport(let underlying): throw StatusAPIError.transport(underlying)
            case .notHTTP: throw StatusAPIError.http(-1)
            }
        }

        switch response.statusCode {
        case 200:
            break
        case 429:
            let retryAfter = RetryAfter.parse(response.value(forHTTPHeaderField: "Retry-After"))
            throw StatusAPIError.rateLimited(retryAfter: retryAfter)
        default:
            throw StatusAPIError.http(response.statusCode)
        }

        do {
            return try JSONDecoder().decode(StatusResponse.self, from: data)
        } catch {
            throw StatusAPIError.decoding(error)
        }
    }
}

// MARK: - Observable store

/// Owns the status rendered by `ServiceStatusRow`. Only fetches when the
/// popover opens and the last fetch is older than `refreshTTL`.
@Observable
@MainActor
final class StatusStore {
    enum State {
        case idle
        case loading
        case loaded(StatusResponse, fetchedAt: Date)
        case error(String)
    }

    private(set) var state: State = .idle
    private(set) var lastUpdated: Date?
    private(set) var rateLimitedUntil: Date?

    /// The services the user monitors, kept in step with their toggles.
    private(set) var monitored: Set<KnownComponent>

    /// The latest status, filtered when read so a toggle applies without a refetch.
    var snapshot: StatusSnapshot? {
        guard case .loaded(let response, let fetchedAt) = state else { return nil }
        return StatusSnapshot(response: response, monitored: monitored, fetchedAt: fetchedAt)
    }

    @ObservationIgnored private let client: StatusAPIClient
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var defaultsObserver: (any NSObjectProtocol)?
    private var inFlight = false

    init(client: StatusAPIClient = StatusAPIClient(), defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
        monitored = KnownComponent.monitored(in: defaults)
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadMonitored() }
        }
    }

    isolated deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    private func reloadMonitored() {
        let current = KnownComponent.monitored(in: defaults)
        if current != monitored {
            monitored = current
        }
    }

    /// How long a successful fetch is considered fresh. Popover-open
    /// triggers within this window are no-ops.
    private let refreshTTL: TimeInterval = 300  // 5 minutes

    /// Statuspage is a public CDN and rarely sends 429s, so when one arrives
    /// without a usable Retry-After the store stays quiet for ten minutes.
    private let rateLimitPolicy = RateLimitPolicy(defaultBackoff: 600)

    /// Fetches the status summary if enough time has passed since the
    /// last successful fetch. No-op when the feature is off, no
    /// components are monitored, a fetch is already in flight, or the
    /// cached snapshot is still within `refreshTTL`.
    func refreshIfStale() async {
        guard defaults[SettingsKeys.serviceStatusEnabled], !monitored.isEmpty else { return }
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
            let fetchedAt = Date()
            state = .loaded(response, fetchedAt: fetchedAt)
            lastUpdated = fetchedAt
            rateLimitedUntil = nil
        } catch StatusAPIError.rateLimited(let retryAfter) {
            let backoff = rateLimitPolicy.cooldown(retryAfter: retryAfter)
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
}
