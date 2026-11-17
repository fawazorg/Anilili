import AVFoundation
import Foundation
import SharedCore
import XCTest
@testable import PlaybackPOC

/// Exercises the same actions as JourneyView, including real AVPlayer time progression.
/// UI rendering/accessibility identifiers still require interactive or UI-runner validation.
@MainActor
final class JourneyTests: XCTestCase {
    private func waitUntil(_ label: String, timeout: TimeInterval = 20, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out: \(label)")
    }

    private func openDemo(_ model: JourneyModel) async throws {
        model.loadCatalog()
        try await waitUntil("shared catalog loaded") { !model.catalogModel.isLoading }
        XCTAssertNil(model.catalogModel.errorMessage)
        XCTAssertEqual(model.catalogModel.items.count, 2)
        guard let anime = model.catalogModel.items.first else { XCTFail("Catalog empty"); return }
        model.openAnime(anime.id)
        try await waitUntil("shared details and episodes loaded") { !model.detailsModel.isLoading && !model.isLoadingEpisodes }
        XCTAssertNil(model.detailsModel.errorMessage)
        XCTAssertNil(model.episodesError)
        XCTAssertEqual(model.detailsModel.media?.id, anime.id)
        XCTAssertEqual(model.episodes.count, 4)
        XCTAssertEqual(model.path, [.details(anime.id)])
    }

    private func playJourney(_ episodeID: String) async throws {
        let model = JourneyModel()
        defer { model.leaveJourney() }
        try await openDemo(model)
        guard let episode = model.episodes.first(where: { $0.id == episodeID }) else { XCTFail("Missing episode"); return }
        model.selectEpisode(episode)
        try await waitUntil("episode resolved and playback progressed") {
            model.selectedEpisode?.id == episodeID && model.playback.seconds > 1 && model.playback.player.timeControlStatus == .playing
        }
        XCTAssertNil(model.resolutionError)
        XCTAssertNil(model.playback.errorMessage)
        XCTAssertEqual(model.path, [.details(episode.animeId), .playback(episode.id)])
        print("Journey selected anime=\(episode.animeId), episode=\(episode.id), state=\(model.playback.state), progressed=\(model.playback.seconds)")
        // NavigationStack back writes the same path binding; didSet releases the player.
        model.path.removeLast()
        XCTAssertEqual(model.path, [.details(episode.animeId)])
        XCTAssertNil(model.selectedEpisode)
        XCTAssertNil(model.playback.player.currentItem)
        XCTAssertEqual(model.playback.state, "Idle")
        XCTAssertEqual(model.playback.seconds, 0)
        XCTAssertEqual(model.episodes.count, 4)
        print("Journey back succeeded; player item released; episode list retained")
    }

    func testCatalogDetailsEpisodeSelectionMP4ProgressionAndBackCleanup() async throws {
        try await playJourney("demo-mp4")
    }

    func testCatalogDetailsEpisodeSelectionHLSProgressionAndBackCleanup() async throws {
        try await playJourney("demo-hls")
    }

    func testEmptyEpisodeListAndMissingSourceAreExplicit() async throws {
        let model = JourneyModel()
        defer { model.leaveJourney() }
        try await openDemo(model)
        let missing = try XCTUnwrap(model.episodes.first(where: { $0.id == "demo-missing" }))
        model.selectEpisode(missing)
        try await waitUntil("missing source error") { model.resolutionError != nil }
        XCTAssertNil(model.playback.player.currentItem)
        XCTAssertNil(model.selectedEpisode)
        model.openAnime(102)
        try await waitUntil("empty season") { !model.detailsModel.isLoading && !model.isLoadingEpisodes }
        XCTAssertTrue(model.episodes.isEmpty)
        XCTAssertNil(model.episodesError)
        XCTAssertEqual(model.detailsModel.media?.id, 102)
    }

    func testInvalidMediaReportsPlayerFailureAndCanReturn() async throws {
        let model = JourneyModel()
        defer { model.leaveJourney() }
        try await openDemo(model)
        let invalid = try XCTUnwrap(model.episodes.first(where: { $0.id == "demo-invalid" }))
        model.selectEpisode(invalid)
        try await waitUntil("invalid media fails") { model.playback.errorMessage != nil }
        XCTAssertEqual(model.playback.state, "Error")
        model.returnToEpisodes()
        XCTAssertNil(model.playback.player.currentItem)
        XCTAssertEqual(model.episodes.count, 4)
    }

    func testRapidTapsResolveOnceAndNavigationCancelsStaleResult() async throws {
        let transport = JourneyProbeTransport()
        let model = JourneyModel(transport: transport)
        defer { model.leaveJourney() }
        try await openDemo(model)
        transport.setMode(.pendingResolve)
        let episode = try XCTUnwrap(model.episodes.first)
        model.selectEpisode(episode)
        model.selectEpisode(episode)
        try await waitUntil("one resolver started") { transport.resolutionCount == 1 }
        XCTAssertEqual(model.resolvingEpisodeID, episode.id)
        model.path = []
        try await waitUntil("native resolve cancelled") { transport.cancellationCount == 1 }
        transport.completePending()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(transport.resolutionCount, 1)
        XCTAssertNil(model.selectedEpisode)
        XCTAssertNil(model.playback.player.currentItem)
        XCTAssertNil(model.resolvingEpisodeID)
        XCTAssertTrue(model.path.isEmpty)
    }

    func testEpisodeHTTPFailureRetriesThroughSharedProvider() async throws {
        let transport = JourneyProbeTransport()
        transport.setMode(.episodesHTTPFailure)
        let model = JourneyModel(transport: transport)
        defer { model.leaveJourney() }
        model.openAnime(101)
        try await waitUntil("HTTP failure displayed") { model.episodesError != nil }
        XCTAssertTrue(model.episodes.isEmpty)
        transport.setMode(.normal)
        model.retryDetails()
        try await waitUntil("retry loads episodes") { !model.isLoadingEpisodes }
        XCTAssertNil(model.episodesError)
        XCTAssertEqual(model.episodes.count, 4)
    }

    func testUnsupportedMediaFormatDoesNotReachPlayer() async throws {
        let transport = JourneyProbeTransport()
        let model = JourneyModel(transport: transport)
        defer { model.leaveJourney() }
        try await openDemo(model)
        transport.setMode(.unsupportedFormat)
        model.selectEpisode(try XCTUnwrap(model.episodes.first))
        try await waitUntil("unsupported format rejected") { model.resolutionError != nil }
        XCTAssertNil(model.playback.player.currentItem)
        XCTAssertNil(model.selectedEpisode)
    }

    func testBackgroundPausesWithoutAutomaticForegroundPlayback() async throws {
        let model = JourneyModel()
        defer { model.leaveJourney() }
        try await openDemo(model)
        model.selectEpisode(try XCTUnwrap(model.episodes.first(where: { $0.id == "demo-mp4" })))
        try await waitUntil("playing before background") { model.playback.seconds > 1 }
        model.background()
        XCTAssertEqual(model.playback.player.rate, 0)
        let position = model.playback.player.currentTime().seconds
        model.foreground()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(model.playback.player.rate, 0)
        XCTAssertEqual(model.playback.player.currentTime().seconds, position, accuracy: 0.25)
        model.returnToEpisodes()
        XCTAssertNil(model.playback.player.currentItem)
    }
}

private final class JourneyProbeTransport: NSObject, CatalogCallbackTransport {
    enum Mode { case normal, pendingResolve, episodesHTTPFailure, unsupportedFormat }
    private let lock = NSLock()
    private let demo = DemoJourneyTransport()
    private var mode: Mode = .normal
    private var pending: CatalogHttpCompletion?
    private var resolutions = 0
    private var cancellations = 0
    var resolutionCount: Int { lock.lock(); defer { lock.unlock() }; return resolutions }
    var cancellationCount: Int { lock.lock(); defer { lock.unlock() }; return cancellations }
    func setMode(_ mode: Mode) { lock.lock(); self.mode = mode; lock.unlock() }
    func post(request: CatalogHttpRequest, completion: CatalogHttpCompletion) -> CatalogCancellation {
        lock.lock()
        let selectedMode = mode
        let isResolve = request.url == "demo://episodes" && request.body.contains("\"operation\":\"resolve\"")
        if isResolve { resolutions += 1 }
        if isResolve && selectedMode == .pendingResolve { pending = completion }
        lock.unlock()
        if isResolve && selectedMode == .pendingResolve {
            return JourneyProbeCancellation { [weak self] in
                guard let self else { return }
                self.lock.lock(); self.cancellations += 1; self.lock.unlock()
            }
        }
        if request.url == "demo://episodes" && !isResolve && selectedMode == .episodesHTTPFailure {
            completion.complete(response: CatalogHttpResponse(status: 503, body: "{}"), error: nil)
            return JourneyProbeCancellation {}
        }
        if isResolve && selectedMode == .unsupportedFormat {
            completion.complete(response: CatalogHttpResponse(status: 200, body: "{\"source\":{\"episodeId\":\"demo-mp4\",\"url\":\"https://example.invalid/video.mpd\",\"format\":\"DASH\"}}"), error: nil)
            return JourneyProbeCancellation {}
        }
        return demo.post(request: request, completion: completion)
    }
    func completePending() {
        lock.lock(); let callback = pending; pending = nil; lock.unlock()
        callback?.complete(response: CatalogHttpResponse(status: 200, body: "{\"source\":{\"episodeId\":\"demo-mp4\",\"url\":\"fixture://progressive.mp4\",\"format\":\"MP4\"}}"), error: nil)
    }
}
private final class JourneyProbeCancellation: NSObject, CatalogCancellation {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action; super.init() }
    func cancel() { action() }
}
