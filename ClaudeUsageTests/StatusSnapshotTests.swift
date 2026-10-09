//
//  StatusSnapshotTests.swift
//  ClaudeUsageTests
//
//  The status row only reflects the services the user monitors. The filter
//  is applied when the snapshot is read, so changing a toggle takes effect
//  without waiting for the next fetch.
//

import Foundation
import Testing
@testable import ClaudeUsage

@Suite("StatusSnapshot")
struct StatusSnapshotTests {

    @Test("only monitored components count toward the severity")
    func severityFollowsMonitoredSet() {
        let response = makeResponse(components: [
            (.claudeAI, "operational"),
            (.claudeAPI, "partial_outage"),
        ])

        let narrow = StatusSnapshot(response: response, monitored: [.claudeAI], fetchedAt: Date())
        let wide = StatusSnapshot(response: response, monitored: [.claudeAI, .claudeAPI], fetchedAt: Date())

        #expect(narrow.displaySeverity == .operational)
        #expect(narrow.affectedComponents.isEmpty)
        #expect(wide.displaySeverity == .major)
        #expect(wide.affectedComponents.map(\.name) == ["Claude API"])
    }

    @Test("affected components are listed worst first")
    func worstFirst() {
        let response = makeResponse(components: [
            (.claudeAI, "degraded_performance"),
            (.claudeCode, "major_outage"),
            (.claudeAPI, "under_maintenance"),
        ])

        let snapshot = StatusSnapshot(response: response, monitored: [.claudeAI, .claudeCode, .claudeAPI], fetchedAt: Date())

        #expect(snapshot.affectedComponents.map(\.severity) == [.critical, .minor, .maintenance])
    }

    @Test("page-wide incidents always show; component incidents only when monitored")
    func incidentFiltering() {
        let response = makeResponse(
            components: [(.claudeAI, "operational")],
            incidents: [
                ("page-wide", []),
                ("api-only", [.claudeAPI]),
                ("claude-ai", [.claudeAI]),
            ]
        )

        let snapshot = StatusSnapshot(response: response, monitored: [.claudeAI], fetchedAt: Date())

        #expect(snapshot.relevantIncidents.map(\.name) == ["page-wide", "claude-ai"])
    }
}

@Suite("StatusStore")
struct StatusStoreTests {

    @Test("toggling a monitored service updates the snapshot without a new fetch")
    func toggleAppliesImmediately() async throws {
        let defaults = TestDefaults.make()
        let url = StubURLProtocol.uniqueURL()
        let body = """
        {"status": {"indicator": "minor", "description": "Partial System Outage"},
         "components": [{"id": "\(KnownComponent.claudeAPI.rawValue)", "name": "Claude API", "status": "partial_outage"}],
         "incidents": []}
        """
        StubURLProtocol.stub(url) { _ in .init(status: 200, body: Data(body.utf8)) }
        let session = URLSession(configuration: StubURLProtocol.configuration(base: HTTPClient.configuration()))
        let store = StatusStore(client: StatusAPIClient(endpoint: url, http: HTTPClient(session: session)), defaults: defaults)

        await store.refreshIfStale()
        #expect(store.snapshot?.displaySeverity == .operational)

        defaults.set(true, forKey: KnownComponent.claudeAPI.setting.name)
        for _ in 0..<50 where store.snapshot?.displaySeverity != .major {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(store.snapshot?.displaySeverity == .major)
        #expect(StubURLProtocol.requests(to: url).count == 1)
    }
}

private func makeResponse(
    components: [(KnownComponent, String)],
    incidents: [(String, [KnownComponent])] = []
) -> StatusResponse {
    StatusResponse(
        status: .init(indicator: "none", description: "All Systems Operational"),
        components: components.map { .init(id: $0.0.rawValue, name: $0.0.displayName, status: $0.1) },
        incidents: incidents.map { name, affected in
            .init(
                id: name,
                name: name,
                status: "investigating",
                shortlink: nil,
                components: affected.map { .init(id: $0.rawValue, name: $0.displayName, status: "major_outage") }
            )
        }
    )
}
