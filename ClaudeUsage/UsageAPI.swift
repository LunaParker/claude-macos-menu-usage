//
//  UsageAPI.swift
//  Menu Bar Usage for Claude
//
//  Client and wire format for the undocumented `/api/oauth/usage`
//  endpoint that Claude Code uses for its status line.
//

import Foundation

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

/// One entry in the generalised `limits` array — the successor to the
/// per-model `seven_day_*` fields. The model-scoped weekly quota
/// (currently Fable, Max 5x/20x plans only) is exposed *only* here;
/// there is no legacy `seven_day_fable` field. `percent` is an integer
/// 0…100 on the wire, and `scope.model.display_name` carries the
/// user-facing name for the scoped model.
struct LimitEntry: Decodable, Sendable {
    let kind: String?
    let percent: Double?
    let resetsAt: Date?
    let scope: Scope?

    struct Scope: Decodable, Sendable {
        let model: Model?

        struct Model: Decodable, Sendable {
            let displayName: String?

            enum CodingKeys: String, CodingKey {
                case displayName = "display_name"
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case percent
        case resetsAt = "resets_at"
        case scope
    }
}

/// The full response from `GET https://api.anthropic.com/api/oauth/usage`.
/// Only the fields we actually render are modelled.
struct UsageResponse: Decodable, Sendable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDayOpus: UsageWindow?
    let limits: [LimitEntry]?
    let extraUsage: ExtraUsageResponse?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case limits
        case extraUsage = "extra_usage"
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
    var http: HTTPClient = .shared

    func fetch(using credentials: ClaudeCredentials) async throws -> UsageResponse {
        if credentials.isExpired {
            throw UsageAPIError.credentialExpired
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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

        switch response.statusCode {
        case 200:
            break
        case 401, 403:
            throw UsageAPIError.unauthorized
        case 429:
            let retryAfter = RetryAfter.parse(response.value(forHTTPHeaderField: "Retry-After"))
            throw UsageAPIError.rateLimited(retryAfter: retryAfter)
        default:
            throw UsageAPIError.http(response.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
        do {
            return try decoder.decode(UsageResponse.self, from: data)
        } catch {
            throw UsageAPIError.decoding(error)
        }
    }
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
