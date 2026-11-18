import AVFoundation
import Foundation
import SharedCore
import XCTest
@testable import PlaybackPOC

/// Controlled original-media fixtures exercise the real Kotlin resolver, native HTTP and AVPlayer.
/// These results establish fixture compatibility, not live AniDB availability or device support.
@MainActor
final class ProviderCompatibilityTests: XCTestCase {
    private let origin = "http://127.0.0.1:8765"

    private func waitUntil(_ label: String, timeout: TimeInterval = 20, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out: \(label)")
    }

    private func model() -> ProviderPlaybackModel {
        ProviderPlaybackModel(transport: URLSessionCatalogTransport(allowLoopback: true))
    }

    private func audit(clear: Bool = false) async throws -> [[String: Any]] {
        let (data, response) = try await URLSession.shared.data(from: URL(string: origin + "/provider/requests" + (clear ? "?clear=1" : ""))!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    func testSharedKnownServerMP4ResolutionActuallyPlaysAndReleasesResources() async throws {
        let value = model()
        defer { value.stop() }
        value.resolveAndPlay(endpoint: origin + "/provider/anidb/mp4")
        try await waitUntil("resolved MP4 progresses") {
            value.playback.seconds > 1 && value.playback.player.timeControlStatus == .playing
        }
        XCTAssertNil(value.errorMessage)
        XCTAssertNil(value.playback.errorMessage)
        XCTAssertEqual(value.resolvedFormat, "MP4")
        print("Controlled provider MP4: state=\(value.playback.state), progressed=\(value.playback.seconds)")
        value.background()
        XCTAssertEqual(value.playback.player.rate, 0)
        let pausedAt = value.playback.player.currentTime().seconds
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(value.playback.player.currentTime().seconds, pausedAt, accuracy: 0.25)
        value.playback.play()
        try await waitUntil("manual playback recovers after background pause") { value.playback.seconds > pausedAt + 0.3 }
        value.stop()
        XCTAssertNil(value.playback.player.currentItem)
        XCTAssertFalse(value.isResolving)
    }

    func testRelativeHLSResolutionPlaysAndExposesManifestAudioAndSubtitles() async throws {
        let value = model()
        defer { value.stop() }
        value.resolveAndPlay(endpoint: origin + "/provider/anidb/relative")
        try await waitUntil("relative HLS and manifest tracks") {
            value.playback.seconds > 1 && value.playback.player.timeControlStatus == .playing &&
            value.playback.audioOptions.count >= 2 && !value.playback.subtitleOptions.isEmpty
        }
        XCTAssertNil(value.errorMessage)
        XCTAssertEqual(value.resolvedFormat, "HLS")
        print("Controlled provider relative HLS progressed=\(value.playback.seconds), audio=\(value.playback.audioOptions.count), subtitles=\(value.playback.subtitleOptions.count)")
    }

    func testGatedHLSForwardsPublicUserAgentAndScopedCookieToPlaylistSegmentAndKey() async throws {
        _ = try await audit(clear: true)
        let value = model()
        defer { value.stop() }
        value.resolveAndPlay(endpoint: origin + "/provider/anidb/gated")
        try await waitUntil("gated encrypted original HLS progresses") {
            value.playback.seconds > 1 && value.playback.player.timeControlStatus == .playing
        }
        XCTAssertNil(value.errorMessage)
        XCTAssertNil(value.playback.errorMessage)
        value.playback.pause()
        let requests = try await audit().filter { ($0["path"] as? String)?.hasPrefix("/provider/gated/") == true }
        XCTAssertTrue(requests.contains { ($0["path"] as? String)?.hasSuffix("master.m3u8") == true })
        XCTAssertTrue(requests.contains { ($0["path"] as? String)?.hasSuffix("index.m3u8") == true })
        XCTAssertTrue(requests.contains { ($0["path"] as? String)?.hasSuffix("key.bin") == true })
        XCTAssertTrue(requests.contains { ($0["path"] as? String)?.hasSuffix(".ts") == true })
        XCTAssertTrue(requests.allSatisfy { $0["userAgentMatched"] as? Bool == true && $0["cookieMatched"] as? Bool == true },
                      "Every relevant HLS request must carry the required public options, not just the top-level URL")
        print("Controlled provider gated HLS: progressed=\(value.playback.seconds), audited media requests=\(requests.count)")
    }

    func testMetadataRedirectChainCompletesBeforePlayback() async throws {
        _ = try await audit(clear: true)
        let value = model()
        defer { value.stop() }
        value.resolveAndPlay(endpoint: origin + "/provider/redirect/2")
        try await waitUntil("redirected metadata resolves and media progresses") { value.playback.seconds > 1 }
        let paths = try await audit().compactMap { $0["path"] as? String }
        XCTAssertTrue(paths.contains("/provider/redirect/2"))
        XCTAssertTrue(paths.contains("/provider/redirect/1"))
        XCTAssertTrue(paths.contains("/provider/anidb/hls"))
        XCTAssertNil(value.errorMessage)
    }

    func testCrossOriginRedirectBuildsAFreshRequestWithoutCredentialsOrBody() {
        let initial = URL(string: "https://origin.fixture.invalid/resolve")!
        let destination = URL(string: "https://destination.fixture.invalid/resolve")!
        var proposed = URLRequest(url: destination)
        proposed.httpMethod = "GET"
        for name in ["Cookie", "Authorization", "Referer", "X-Fixture-Secret"] {
            proposed.setValue("original-test-only", forHTTPHeaderField: name)
        }
        proposed.setValue("application/json", forHTTPHeaderField: "Accept")
        proposed.setValue("AnililiFixture/1.0", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: initial)
        let response = HTTPURLResponse(url: initial, statusCode: 302, httpVersion: nil,
                                       headerFields: ["Location": destination.absoluteString])!
        let policy = ProviderRedirectDelegate(initialURL: initial, allowLoopback: false)
        var calls = 0
        policy.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: proposed) { request in
            calls += 1
            XCTAssertEqual(request?.url, destination)
            XCTAssertEqual(request?.httpMethod, "GET")
            XCTAssertNil(request?.httpBody)
            XCTAssertEqual(request?.httpShouldHandleCookies, false)
            XCTAssertEqual(request?.value(forHTTPHeaderField: "User-Agent"), "AnililiFixture/1.0")
            for name in ["Cookie", "Authorization", "Referer", "X-Fixture-Secret"] {
                XCTAssertNil(request?.value(forHTTPHeaderField: name), name)
            }
        }
        XCTAssertEqual(calls, 1)
        proposed.httpMethod = "POST"
        proposed.httpBody = Data("original-test-only-body".utf8)
        policy.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: proposed) { request in
            calls += 1
            XCTAssertNil(request, "Cross-origin request bodies must not be forwarded")
        }
        XCTAssertEqual(calls, 2)
    }

    func testCrossOriginMetadataRedirectDoesNotForwardSyntheticCredentials() async throws {
        _ = try await audit(clear: true)
        let transport = URLSessionCatalogTransport(allowLoopback: true)
        let completed = expectation(description: "redirect result")
        let request = CatalogHttpRequest(url: origin + "/provider/redirect-cross-origin", body: "", method: "GET",
            headers: ["Cookie": "fixture_session=authorized", "Authorization": "Bearer original-test-only", "X-Fixture-Secret": "original-test-only"])
        let handle = transport.post(request: request, completion: ProviderHTTPProbe { response, error in
            XCTAssertNil(error)
            XCTAssertEqual(response?.status, 200)
            XCTAssertEqual(URL(string: response?.finalUrl ?? "")?.host, "localhost")
            completed.fulfill()
        })
        defer { handle.cancel() }
        await fulfillment(of: [completed], timeout: 10)
        let requests = try await audit()
        XCTAssertTrue(requests.contains { $0["path"] as? String == "/provider/redirect-cross-origin" && $0["cookieMatched"] as? Bool == true })
        let redirected = try XCTUnwrap(requests.first { $0["path"] as? String == "/provider/anidb/hls" })
        XCTAssertEqual(redirected["method"] as? String, "GET")
        XCTAssertEqual(redirected["cookieMatched"] as? Bool, false)
        XCTAssertEqual(redirected["authorizationPresent"] as? Bool, false)
        XCTAssertEqual(redirected["customHeaderPresent"] as? Bool, false)
        XCTAssertEqual(redirected["refererPresent"] as? Bool, false)
    }

    func testExpiredMalformedAndUnsupportedRequirementsNeverCreateAPlayerItem() async throws {
        for scenario in ["expired", "malformed", "unsupported-headers", "unsupported-policy", "unsupported"] {
            let value = model()
            value.resolveAndPlay(endpoint: origin + "/provider/anidb/" + scenario)
            try await waitUntil("explicit failure: \(scenario)") { !value.isResolving }
            XCTAssertNotNil(value.errorMessage, scenario)
            XCTAssertNil(value.playback.player.currentItem, scenario)
            value.stop()
        }
    }

    func testAuthenticationErrorsDoNotRetryAndTransientErrorsAreBounded() async throws {
        for status in [401, 403, 404, 429, 503] {
            _ = try await audit(clear: true)
            let value = model()
            value.resolveAndPlay(endpoint: origin + "/provider/status/\(status)")
            try await waitUntil("HTTP \(status) fails explicitly") { !value.isResolving }
            XCTAssertNotNil(value.errorMessage)
            XCTAssertNil(value.playback.player.currentItem)
            let requests = try await audit().filter { $0["path"] as? String == "/provider/status/\(status)" }
            XCTAssertEqual(requests.count, [429, 503].contains(status) ? 3 : 1)
            value.stop()
        }
    }

    func testNativeHTTPDeadlineCancelsSlowRequestAndSuppressesLateResponse() async throws {
        _ = try await audit(clear: true)
        let client = AniDbSourceClient(transport: URLSessionCatalogTransport(allowLoopback: true), timeoutMs: 1_000)
        defer { client.close() }
        let failed = expectation(description: "bounded native HTTP deadline")
        let probe = ProviderSourceProbe { source, failure in
            XCTAssertNil(source)
            XCTAssertEqual(failure?.kind.name, "TIMEOUT")
            failed.fulfill()
        }
        let handle = client.resolve(endpoint: origin + "/provider/timeout?seconds=3", episodeId: "slow-fixture",
                                    nowMs: Int64(Date().timeIntervalSince1970 * 1_000), completion: probe)
        defer { handle.cancel() }
        await fulfillment(of: [failed], timeout: 6)
        // A response arriving after the deadline must not deliver another result or start retries.
        try await Task.sleep(nanoseconds: 3_200_000_000)
        XCTAssertEqual(probe.callCount, 1)
        let requests = try await audit().filter { $0["path"] as? String == "/provider/timeout" }
        XCTAssertEqual(requests.count, 1)
    }

    func testRapidTapsAreSingleFlightAndCancelledLateCompletionCannotPlay() async throws {
        let transport = PendingProviderTransport()
        let value = ProviderPlaybackModel(transport: transport)
        defer { value.stop() }
        value.resolveAndPlay(endpoint: "https://example.invalid/known-server/iframe")
        value.resolveAndPlay(endpoint: "https://example.invalid/known-server/iframe")
        try await waitUntil("single resolver started") { transport.requestCount == 1 }
        value.cancel()
        try await waitUntil("underlying request cancelled") { transport.cancelCount == 1 }
        transport.completeLate(body: "{\"link\":\"\(origin)/progressive.mp4\",\"format\":\"MP4\"}")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(transport.requestCount, 1)
        XCTAssertFalse(value.isResolving)
        XCTAssertNil(value.playback.player.currentItem)
        XCTAssertNil(value.errorMessage)
    }
}

private final class ProviderHTTPProbe: NSObject, CatalogHttpCompletion {
    private let receive: (CatalogHttpResponse?, String?) -> Void
    init(_ receive: @escaping (CatalogHttpResponse?, String?) -> Void) { self.receive = receive; super.init() }
    func complete(response: CatalogHttpResponse?, error: String?) { receive(response, error) }
}

private final class PendingProviderTransport: NSObject, CatalogCallbackTransport {
    private let lock = NSLock()
    private var completion: CatalogHttpCompletion?
    private var requests = 0
    private var cancellations = 0
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return requests }
    var cancelCount: Int { lock.lock(); defer { lock.unlock() }; return cancellations }
    func post(request: CatalogHttpRequest, completion: CatalogHttpCompletion) -> CatalogCancellation {
        lock.lock(); requests += 1; self.completion = completion; lock.unlock()
        return ProviderProbeCancellation { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.cancellations += 1; self.lock.unlock()
        }
    }
    func completeLate(body: String) {
        lock.lock(); let value = completion; completion = nil; lock.unlock()
        value?.complete(response: CatalogHttpResponse(status: 200, body: body), error: nil)
    }
}
private final class ProviderProbeCancellation: NSObject, CatalogCancellation {
    private let cancelRequest: () -> Void
    init(_ action: @escaping () -> Void) { cancelRequest = action; super.init() }
    func cancel() { cancelRequest() }
}

private final class ProviderSourceProbe: NSObject, EpisodeSourceCompletion {
    private let lock = NSLock()
    private var calls = 0
    private let receive: (PlaybackSource?, CatalogFailure?) -> Void
    init(_ receive: @escaping (PlaybackSource?, CatalogFailure?) -> Void) { self.receive = receive; super.init() }
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func complete(source: PlaybackSource?, failure: CatalogFailure?) {
        lock.lock(); calls += 1; lock.unlock()
        receive(source, failure)
    }
}
