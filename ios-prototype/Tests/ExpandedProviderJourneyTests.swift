import AVFoundation
import Foundation
import SharedCore
import XCTest
@testable import PlaybackPOC

/// Real URLSession requests carry raw provider-shaped fixtures into Kotlin, then AVPlayer.
/// These tests prove controlled compatibility, never current live-provider availability.
@MainActor
final class ExpandedProviderJourneyTests: XCTestCase {
    private func waitUntil(_ label: String, timeout: TimeInterval = 25, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out: \(label)")
    }

    private func model(_ providerId: String, transport: CatalogCallbackTransport? = nil,
                       history: WatchHistoryModel? = nil) -> JourneyModel {
        let base = "http://127.0.0.1:8765/provider/expanded/\(providerId)"
        let native = transport ?? URLSessionCatalogTransport(allowLoopback: true)
        return JourneyModel(transport: native, history: history, providerId: providerId,
            providerTransport: native, providerBaseURL: base, embedBaseURL: base,
            catalogEndpoint: base + "/catalog")
    }

    private func openCatalogAndEpisodes(_ model: JourneyModel) async throws {
        model.loadCatalog()
        try await waitUntil("shared provider catalog") { !model.catalogModel.isLoading }
        XCTAssertNil(model.catalogModel.errorMessage)
        XCTAssertEqual(model.catalogModel.items.first?.title.preferred, "Original Provider Fixture")
        let anime = try XCTUnwrap(model.catalogModel.items.first)
        model.openAnime(anime.id)
        try await waitUntil("shared provider details and episodes") { !model.detailsModel.isLoading && !model.isLoadingEpisodes }
        XCTAssertNil(model.detailsModel.errorMessage)
        XCTAssertNil(model.episodesError)
        XCTAssertEqual(model.detailsModel.media?.id, anime.id)
        XCTAssertEqual(model.episodes.map(\.number), [1, 2])
        XCTAssertEqual(model.episodes.first?.id, "\(model.providerId):sub:1")
    }

    private func assertProgressAndCleanup(_ model: JourneyModel, episode: Episode) async throws {
        try await waitUntil("resolved fixture playback progression") {
            model.playback.seconds > 1 && model.playback.player.timeControlStatus == .playing
        }
        XCTAssertNil(model.resolutionError)
        XCTAssertNil(model.playback.errorMessage)
        XCTAssertEqual(model.selectedEpisode?.id, episode.id)
        XCTAssertEqual(model.path, [.details(episode.animeId), .playback(episode.id)])
        print("Expanded provider=\(model.providerId), episode=\(episode.id), state=\(model.playback.state), progressed=\(model.playback.seconds)")
        model.returnToEpisodes()
        XCTAssertNil(model.playback.player.currentItem)
        XCTAssertNil(model.selectedEpisode)
        XCTAssertEqual(model.path, [.details(episode.animeId)])
        XCTAssertGreaterThan(model.history.record(for: episode)?.positionMs ?? 0, 0)
        XCTAssertEqual(model.history.record(for: episode)?.identity.providerId, model.providerId)
    }

    func testAniPmCatalogDetailsMP4ProgressionAndBackCleanup() async throws {
        let journey = model("anipm")
        defer { journey.leaveJourney() }
        try await openCatalogAndEpisodes(journey)
        let episode = try XCTUnwrap(journey.episodes.first)
        journey.selectEpisode(episode)
        try await assertProgressAndCleanup(journey, episode: episode)
    }

    func testAniChanCatalogDetailsImageMimeHLSProgressionAndBackCleanup() async throws {
        let journey = model("anichan")
        defer { journey.leaveJourney() }
        try await openCatalogAndEpisodes(journey)
        let episode = try XCTUnwrap(journey.episodes.first)
        journey.selectEpisode(episode)
        try await assertProgressAndCleanup(journey, episode: episode)
    }

    func testExternalSubtitlesRequireFreshConsentBeforeProviderHLSPlayback() async throws {
        for provider in ["anipm", "anichan"] {
            let journey = model(provider)
            defer { journey.leaveJourney() }
            try await openCatalogAndEpisodes(journey)
            let episode = try XCTUnwrap(journey.episodes.last)
            journey.selectEpisode(episode)
            try await waitUntil("explicit external subtitle warning") { journey.requiresSubtitleConsent }
            XCTAssertNil(journey.playback.player.currentItem)
            XCTAssertNil(journey.selectedEpisode)
            journey.cancelResolution()
            journey.playWithoutExternalSubtitles()
            XCTAssertNil(journey.playback.player.currentItem, "Cancelled consent cannot start media")
            journey.selectEpisode(episode)
            try await waitUntil("new selection needs its own consent") { journey.requiresSubtitleConsent }
            journey.playWithoutExternalSubtitles()
            try await assertProgressAndCleanup(journey, episode: episode)
        }
    }

    func testProviderHTTPFailureRetriesAndBackgroundCancelsObsoleteResolution() async throws {
        let transport = ExpandedJourneyProbeTransport()
        transport.setMode(.httpFailure)
        let journey = model("anipm", transport: transport)
        defer { journey.leaveJourney() }
        journey.openAnime(101)
        try await waitUntil("provider error presentation") { journey.episodesError != nil }
        XCTAssertTrue(journey.episodes.isEmpty)
        XCTAssertNil(journey.playback.player.currentItem)
        transport.setMode(.normal)
        journey.retryDetails()
        try await waitUntil("provider retry") { !journey.isLoadingEpisodes }
        XCTAssertNil(journey.episodesError)
        let episode = try XCTUnwrap(journey.episodes.first)
        transport.setMode(.pending)
        journey.selectEpisode(episode)
        journey.selectEpisode(episode)
        try await waitUntil("single resolver request") { transport.pendingCount == 1 }
        journey.background()
        try await waitUntil("native request cancellation") { transport.cancellationCount == 1 }
        transport.completeLate()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(transport.pendingCount, 1)
        XCTAssertNil(journey.resolvingEpisodeID)
        XCTAssertFalse(journey.requiresSubtitleConsent)
        XCTAssertNil(journey.selectedEpisode)
        XCTAssertNil(journey.playback.player.currentItem)
        XCTAssertNil(journey.resolutionError)
    }

    func testProviderHistoryIsIsolatedAndResumeRestoresAudioAfterRecreation() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("history.json")
        let first = WatchHistoryModel(storage: HistoryFileStorage(fileURL: url), providerId: "anipm")
        let dubbed = Episode(id: "anipm:dub:1", animeId: 101, number: 1, title: "Episode 1 · DUB")
        _ = first.begin(episode: dubbed, animeTitle: "Original Provider Fixture")
        first.sample(positionSeconds: 6, durationSeconds: 120, immediate: true)
        first.endSession()
        let other = WatchHistoryModel(storage: HistoryFileStorage(fileURL: url), providerId: "anichan")
        XCTAssertNil(other.record(for: dubbed))
        XCTAssertTrue(other.continuing.isEmpty)
        let recreated = WatchHistoryModel(storage: HistoryFileStorage(fileURL: url), providerId: "anipm")
        XCTAssertEqual(recreated.record(for: dubbed)?.positionMs, 6_000)
        let journey = model("anipm", history: recreated)
        defer { journey.leaveJourney() }
        journey.continueWatching(try XCTUnwrap(recreated.continuing.first))
        try await waitUntil("provider persisted resume progression") {
            journey.playback.appliedResumeSeconds >= 2.9 && journey.playback.seconds > 3.5
        }
        XCTAssertEqual(journey.audio, "dub")
        XCTAssertEqual(journey.selectedEpisode?.id, dubbed.id)
        XCTAssertEqual(journey.resumeFromSeconds, 3, accuracy: 0.1)
        XCTAssertNil(journey.playback.errorMessage)
    }
}

private final class ExpandedJourneyProbeTransport: NSObject, CatalogCallbackTransport {
    enum Mode { case normal, httpFailure, pending }
    private let native = URLSessionCatalogTransport(allowLoopback: true)
    private let lock = NSLock()
    private var mode: Mode = .normal
    private var pending: CatalogHttpCompletion?
    private var pendingRequests = 0
    private var cancellations = 0
    var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return pendingRequests }
    var cancellationCount: Int { lock.lock(); defer { lock.unlock() }; return cancellations }
    func setMode(_ mode: Mode) { lock.lock(); self.mode = mode; lock.unlock() }
    func post(request: CatalogHttpRequest, completion: CatalogHttpCompletion) -> CatalogCancellation {
        lock.lock()
        let selectedMode = mode
        let providerRequest = !request.url.hasSuffix("/catalog")
        if providerRequest && selectedMode == .pending { pending = completion; pendingRequests += 1 }
        lock.unlock()
        if providerRequest && selectedMode == .httpFailure {
            completion.complete(response: CatalogHttpResponse(status: 503, body: "{}"), error: nil)
            return ExpandedJourneyCancellation {}
        }
        if providerRequest && selectedMode == .pending {
            return ExpandedJourneyCancellation { [weak self] in
                guard let self else { return }
                self.lock.lock(); self.cancellations += 1; self.lock.unlock()
            }
        }
        return native.post(request: request, completion: completion)
    }
    func completeLate() {
        lock.lock(); let completion = pending; pending = nil; lock.unlock()
        completion?.complete(response: CatalogHttpResponse(status: 200, body: "{}"), error: nil)
    }
}
private final class ExpandedJourneyCancellation: NSObject, CatalogCancellation {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action; super.init() }
    func cancel() { action() }
}
