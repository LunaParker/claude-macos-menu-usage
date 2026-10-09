//
//  HTTPClient.swift
//  Menu Bar Usage for Claude
//
//  The network session both API clients share, and the Retry-After and
//  cooldown rules they have in common.
//

import Foundation

/// Sends requests for both API clients and stamps them with the app's User-Agent.
struct HTTPClient: Sendable {
    enum Failure: Error {
        case transport(Error)
        case notHTTP
    }

    static let shared = HTTPClient(session: URLSession(configuration: configuration()))

    let session: URLSession

    /// Ephemeral with no URL cache: the usage request carries the bearer token,
    /// and nothing it sends or receives may be written to disk.
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return configuration
    }

    static func userAgent(version: String) -> String {
        "MenuBarUsageForClaude/\(version) (macOS menu bar)"
    }

    private static let userAgentHeader = userAgent(
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    )

    func send(_ request: URLRequest) async throws(Failure) -> (Data, HTTPURLResponse) {
        var request = request
        request.setValue(Self.userAgentHeader, forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw .transport(error)
        }
        guard let http = response as? HTTPURLResponse else { throw .notHTTP }
        return (data, http)
    }
}

/// Parses a `Retry-After` header: integer seconds or an HTTP-date. Anything under
/// one second is nil, so a stray `Retry-After: 0` can't switch a cooldown off.
enum RetryAfter {
    static func parse(_ value: String?) -> TimeInterval? {
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

/// How long to stay quiet after a 429: the server's hint when it gives one,
/// never less than `minimumBackoff`.
struct RateLimitPolicy {
    let defaultBackoff: TimeInterval
    var minimumBackoff: TimeInterval = 60

    func cooldown(retryAfter: TimeInterval?) -> TimeInterval {
        max(retryAfter ?? defaultBackoff, minimumBackoff)
    }
}

/// The on-disk URL cache that `URLSession.shared` used to fill, which held
/// copies of the bearer token. Removing it is safe on every launch.
enum LegacyURLCache {
    private static let names = ["Cache.db", "Cache.db-shm", "Cache.db-wal", "fsCachedData"]

    static func remove(cachesDirectory: URL, bundleIdentifier: String) {
        let folder = cachesDirectory.appendingPathComponent(bundleIdentifier, isDirectory: true)
        for name in names {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    static func removeForThisApp() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier,
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return }
        remove(cachesDirectory: caches, bundleIdentifier: bundleIdentifier)
    }
}
