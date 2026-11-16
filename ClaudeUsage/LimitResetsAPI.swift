//
//  LimitResetsAPI.swift
//  Menu Bar Usage for Claude
//
//  The limit resets Anthropic grants (codename `cedar_ember`), read from the
//  usage endpoint. Display only: the app never claims a reset.
//

import Foundation

// MARK: - Wire format

/// The `cedar_ember` block. Only the fields the app shows are modelled.
nonisolated struct LimitResetsBlock: Decodable, Sendable, Equatable {
    var eligible: Bool?
    /// Why resets aren't offered: `surface`, `tier`, `cli_version` and others.
    var ineligibleReason: String?
    var grants: [Grant]
    /// `grants` entries that didn't decode and were skipped.
    var droppedGrants = 0

    struct Grant: Decodable, Sendable, Equatable {
        var id: String
        var resetsLeft: Int?
        var startsAt: Date?
        var endsAt: Date?
        /// Limit keys this reset clears: `five_hour`, `seven_day`, `seven_day_overage_included`.
        var clears: [String]?
        var paused: Bool?
        var usableNow: Bool?

        enum CodingKeys: String, CodingKey {
            case id
            case resetsLeft = "resets_left"
            case startsAt = "starts_at"
            case endsAt = "ends_at"
            case clears
            case paused
            case usableNow = "usable_now"
        }
    }

    enum CodingKeys: String, CodingKey {
        case eligible
        case ineligibleReason = "ineligible_reason"
        case grants
    }
}

nonisolated extension LimitResetsBlock {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eligible = try container.decodeIfPresent(Bool.self, forKey: .eligible)
        ineligibleReason = try container.decodeIfPresent(String.self, forKey: .ineligibleReason)
        let lenient = try container.decodeIfPresent(LenientArray<Grant>.self, forKey: .grants)
        grants = lenient?.elements ?? []
        droppedGrants = lenient?.dropped ?? 0
    }
}

nonisolated private struct LimitResetsEnvelope: Decodable {
    let cedarEmber: LimitResetsBlock?

    enum CodingKeys: String, CodingKey {
        case cedarEmber = "cedar_ember"
    }
}

// MARK: - Client

protocol LimitResetsFetching {
    /// Nil when the response carries no `cedar_ember` block.
    func fetchResets(accessToken: String, cliVersion: String) async throws -> LimitResetsBlock?
}

/// The endpoint only fills the block for Claude Code's surface, so this request
/// leads its User-Agent with `claude-cli/<version>` and keeps the app's own after it.
final class LimitResetsClient: LimitResetsFetching {
    let endpoint: URL
    let http: HTTPClient

    init(endpoint: URL = URL(string: "https://api.anthropic.com/api/oauth/usage")!, http: HTTPClient = .shared) {
        self.endpoint = endpoint
        self.http = http
    }

    /// `skip_spend` drops the spend and Extra Usage fields, which the usage poll already has.
    static func requestURL(endpoint: URL) -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "cedar_ember", value: "1"), URLQueryItem(name: "skip_spend", value: "1")]
        return components.url!
    }

    static func userAgent(cliVersion: String) -> String {
        "claude-cli/\(cliVersion) (external, cli) \(HTTPClient.appUserAgent)"
    }

    func fetchResets(accessToken: String, cliVersion: String) async throws -> LimitResetsBlock? {
        var request = URLRequest(url: Self.requestURL(endpoint: endpoint))
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("cli", forHTTPHeaderField: "x-app")
        request.setValue(Self.userAgent(cliVersion: cliVersion), forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http.send(request)
        } catch {
            switch error {
            case .transport(let underlying): throw UsageAPIError.transport(underlying)
            case .notHTTP: throw UsageAPIError.http(-1)
            }
        }
        try UsageAPIError.check(response, body: data, endpoint: "limit resets")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
        let block: LimitResetsBlock?
        do {
            block = try decoder.decode(LimitResetsEnvelope.self, from: data).cedarEmber
        } catch {
            throw UsageAPIError.decoding(error)
        }
        if let dropped = block?.droppedGrants, dropped > 0 {
            DiagnosticLog.shared.log(.api, "Skipped \(dropped) malformed limit reset grants")
        }
        return block
    }
}
