import Foundation
import SharedCore
import XCTest
@testable import PlaybackPOC

/// The same synthetic JSON is decoded by Kotlin on JVM, Native, and through the Swift adapter.
@MainActor
final class CatalogTests: XCTestCase {
    private func waitUntil(_ label: String, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out: \(label)")
    }

    private func makeClient(_ transport: FixtureCatalogTransport) -> CatalogClient {
        CatalogClient(transport: transport, endpoint: "https://example.invalid/graphql")
    }

    func testSearchUsesSharedParserAndModels() async throws {
        let transport = FixtureCatalogTransport([.reply(200, CatalogFixtures.shared.searchJson)])
        let model = CatalogModel(client: makeClient(transport))
        model.query = "fixture"
        model.search()
        XCTAssertTrue(model.isLoading)
        try await waitUntil("search result") { !model.isLoading }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.items.first?.id, CatalogFixtures.shared.expectedId)
        XCTAssertEqual(model.items.first?.title.preferred, CatalogFixtures.shared.expectedTitle)
        XCTAssertEqual(model.items.first?.episodes?.intValue, 12)
        XCTAssertEqual(model.items.first?.coverImage.best, "https://example.invalid/poster.jpg")
    }

    func testDetailsUsesSharedParserAndDerivedMetadata() async throws {
        let transport = FixtureCatalogTransport([.reply(200, CatalogFixtures.shared.detailsJson)])
        let client = makeClient(transport)
        defer { client.close() }
        let model = CatalogDetailsModel(client: client)
        model.load(id: CatalogFixtures.shared.expectedId)
        try await waitUntil("details result") { !model.isLoading }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.media?.id, CatalogFixtures.shared.expectedId)
        XCTAssertEqual(model.media?.title.preferred, CatalogFixtures.shared.expectedTitle)
        XCTAssertEqual(model.media?.airedEpisodes?.intValue, 4)
        XCTAssertEqual(model.media?.heroImage, "https://example.invalid/backdrop.jpg")
    }

    func testEmptyAndOptionalFields() async throws {
        let transport = FixtureCatalogTransport([
            .reply(200, CatalogFixtures.shared.emptyJson),
            .reply(200, "{\"data\":{\"Page\":{\"media\":[{\"id\":7}]}}}")
        ])
        let model = CatalogModel(client: makeClient(transport))
        model.query = "no match"
        model.search()
        try await waitUntil("empty result") { !model.isLoading }
        XCTAssertTrue(model.hasSearched)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.errorMessage)
        model.query = "minimal"
        model.search()
        try await waitUntil("optional fields") { !model.isLoading }
        XCTAssertEqual(model.items.first?.title.preferred, "Untitled")
        XCTAssertNil(model.items.first?.episodes)
    }

    func testExplicitNullOptionalFieldsMatchSharedDefaults() async throws {
        let transport = FixtureCatalogTransport([.reply(200, CatalogFixtures.shared.optionalNullJson)])
        let client = makeClient(transport)
        defer { client.close() }
        let model = CatalogDetailsModel(client: client)
        model.load(id: 7)
        try await waitUntil("explicit null defaults") { !model.isLoading }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.media?.id, 7)
        XCTAssertEqual(model.media?.title.preferred, "Untitled")
        XCTAssertNil(model.media?.coverImage.best)
        XCTAssertEqual(model.media?.genres, [])
        XCTAssertEqual(model.media?.isAdult, false)
    }

    func testHTTPErrorAndRetry() async throws {
        let transport = FixtureCatalogTransport([
            .reply(503, "unavailable"), .reply(200, CatalogFixtures.shared.searchJson)
        ])
        let model = CatalogModel(client: makeClient(transport))
        model.query = "fixture"
        model.search()
        try await waitUntil("HTTP error") { !model.isLoading }
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.items.isEmpty)
        model.search()
        try await waitUntil("retry") { !model.isLoading }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.items.first?.id, CatalogFixtures.shared.expectedId)
        XCTAssertEqual(transport.requestCount, 2)
    }

    func testMalformedResponseReportsError() async throws {
        let transport = FixtureCatalogTransport([.reply(200, "not JSON")])
        let model = CatalogModel(client: makeClient(transport))
        model.query = "fixture"
        model.search()
        try await waitUntil("malformed response") { !model.isLoading }
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.items.isEmpty)
    }

    func testURLSessionAdapterSuppliesHeadersAndPreservesHTTPStatus() async throws {
        let received = expectation(description: "HTTP response")
        FixtureURLProtocol.configure { request, protocolInstance in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Anilili-iOS-Prototype/0.1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "anilili://ios-playback-poc")
            let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            protocolInstance.client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            protocolInstance.client?.urlProtocol(protocolInstance, didLoad: Data("unavailable".utf8))
            protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport = URLSessionCatalogTransport(session: session)
        _ = transport.post(request: CatalogHttpRequest(url: "https://catalog.fixture.invalid/graphql", body: "{}"), completion: HTTPCompletionProbe { response, error in
            XCTAssertEqual(response?.status, 503)
            XCTAssertEqual(response?.body, "unavailable")
            XCTAssertNil(error)
            received.fulfill()
        })
        await fulfillment(of: [received], timeout: 3)
    }

    func testURLSessionCancellationStopsUnderlyingRequest() async throws {
        let started = expectation(description: "HTTP started")
        let stopped = expectation(description: "HTTP stopped")
        let completed = expectation(description: "Cancellation callback")
        FixtureURLProtocol.configure(start: { _, _ in started.fulfill() }, stop: { stopped.fulfill() })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport = URLSessionCatalogTransport(session: session)
        let handle = transport.post(request: CatalogHttpRequest(url: "https://catalog.fixture.invalid/graphql", body: "{}"), completion: HTTPCompletionProbe { response, error in
            XCTAssertNil(response)
            XCTAssertNotNil(error)
            completed.fulfill()
        })
        await fulfillment(of: [started], timeout: 3)
        handle.cancel()
        await fulfillment(of: [stopped, completed], timeout: 3)
    }

    func testCancellationReachesTransportAndIgnoresLateCompletion() async throws {
        let transport = FixtureCatalogTransport([.pending])
        let model = CatalogModel(client: makeClient(transport))
        model.query = "fixture"
        model.search()
        try await waitUntil("request started") { transport.requestCount == 1 }
        model.cancel()
        try await waitUntil("native request cancelled") { transport.cancelCount == 1 }
        transport.completePending(body: CatalogFixtures.shared.searchJson)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    func testReplacementSearchIgnoresOldResult() async throws {
        let transport = FixtureCatalogTransport([.pending, .reply(200, CatalogFixtures.shared.searchJson)])
        let model = CatalogModel(client: makeClient(transport))
        model.query = "old"
        model.search()
        try await waitUntil("old request started") { transport.requestCount == 1 }
        model.query = "new"
        model.search()
        try await waitUntil("new result") { !model.isLoading }
        transport.completePending(body: CatalogFixtures.shared.searchJson.replacingOccurrences(of: "101", with: "202"))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(model.items.first?.id, CatalogFixtures.shared.expectedId)
        XCTAssertEqual(transport.cancelCount, 1)
    }
}

private final class FixtureCatalogTransport: NSObject, CatalogCallbackTransport {
    enum Reply { case reply(Int32, String), pending }
    private let lock = NSLock()
    private var replies: [Reply]
    private var pending: CatalogHttpCompletion?
    private var requests = 0
    private var cancellations = 0

    init(_ replies: [Reply]) { self.replies = replies; super.init() }
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return requests }
    var cancelCount: Int { lock.lock(); defer { lock.unlock() }; return cancellations }

    func post(request: CatalogHttpRequest, completion: CatalogHttpCompletion) -> CatalogCancellation {
        lock.lock()
        requests += 1
        let reply = replies.isEmpty ? Reply.reply(500, "Unexpected request") : replies.removeFirst()
        if case .pending = reply { pending = completion }
        lock.unlock()
        if case let .reply(status, body) = reply {
            completion.complete(response: CatalogHttpResponse(status: status, body: body), error: nil)
        }
        return FixtureCancellation { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.cancellations += 1; self.lock.unlock()
        }
    }

    func completePending(body: String) {
        lock.lock(); let completion = pending; pending = nil; lock.unlock()
        completion?.complete(response: CatalogHttpResponse(status: 200, body: body), error: nil)
    }
}

private final class FixtureCancellation: NSObject, CatalogCancellation {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action; super.init() }
    func cancel() { action() }
}

private final class HTTPCompletionProbe: NSObject, CatalogHttpCompletion {
    private let receive: (CatalogHttpResponse?, String?) -> Void
    init(_ receive: @escaping (CatalogHttpResponse?, String?) -> Void) { self.receive = receive; super.init() }
    func complete(response: CatalogHttpResponse?, error: String?) { receive(response, error) }
}

private final class FixtureURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var start: ((URLRequest, FixtureURLProtocol) -> Void)?
    private static var stop: (() -> Void)?

    static func configure(start: @escaping (URLRequest, FixtureURLProtocol) -> Void, stop: (() -> Void)? = nil) {
        lock.lock(); Self.start = start; Self.stop = stop; lock.unlock()
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "catalog.fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let action = Self.start; Self.lock.unlock()
        action?(request, self)
    }
    override func stopLoading() {
        Self.lock.lock(); let action = Self.stop; Self.lock.unlock()
        action?()
    }
}
