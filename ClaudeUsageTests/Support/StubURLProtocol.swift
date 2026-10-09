//
//  StubURLProtocol.swift
//  ClaudeUsageTests
//
//  Serves canned HTTP responses to sessions built from `configuration(base:)`.
//  Handlers are keyed by URL, so suites using it can run in parallel.
//

import Foundation
import Synchronization

nonisolated final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()
    }

    typealias Handler = @Sendable (URLRequest) -> Response

    private static let handlers = Mutex<[URL: Handler]>([:])
    private static let received = Mutex<[URL: [URLRequest]]>([:])

    /// A URL no other test uses.
    static func uniqueURL() -> URL {
        URL(string: "https://stub.invalid/\(UUID().uuidString)")!
    }

    static func stub(_ url: URL, handler: @escaping Handler) {
        handlers.withLock { $0[url] = handler }
    }

    static func requests(to url: URL) -> [URLRequest] {
        received.withLock { $0[url] ?? [] }
    }

    /// Routes every request made with the returned configuration to this stub.
    static func configuration(base: URLSessionConfiguration) -> URLSessionConfiguration {
        base.protocolClasses = [StubURLProtocol.self]
        return base
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let handler = Self.handlers.withLock({ $0[url] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        Self.received.withLock { $0[url, default: []].append(request) }
        let stub = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
