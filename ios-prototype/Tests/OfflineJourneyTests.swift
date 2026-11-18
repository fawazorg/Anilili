import AVFoundation
import Foundation
import SharedCore
import XCTest
@testable import PlaybackPOC

@MainActor
final class OfflineJourneyTests: XCTestCase {
    private func waitUntil(_ label: String, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Offline journey timed out: \(label)")
    }
    private func downloaded() async throws -> (OfflineDownloadEngine, DownloadRecord, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let engine = OfflineDownloadEngine(store: OfflineDownloadStore(root: root), allowLoopback: true,
            backgroundIdentifier: "org.anilili.offline-journey-test.\(UUID().uuidString)")
        var handedOff = false
        defer { if !handedOff { engine.shutdown() } }
        let prefix = "http://127.0.0.1:8765/provider/offline/isolated/\(UUID().uuidString)"
        let source = PlaybackSource(episodeId: "demo-mp4", url: prefix + "/media.mp4", format: .mp4, headers: [:])
        let identity = DownloadIdentity(providerId: "demo-v1", animeId: "101", episodeId: "demo-mp4")
        XCTAssertTrue(engine.download(identity: identity, title: "Original Offline Fixture", episodeTitle: "Original Episode",
            source: source, episodeNumber: 1))
        try await waitUntil("MP4 complete") { engine.records.first?.state == .completed }
        let record = try XCTUnwrap(engine.records.first)
        var disable = URLRequest(url: try XCTUnwrap(URL(string: prefix + "/disable")))
        disable.httpMethod = "POST"; disable.httpBody = Data("{}".utf8)
        let (_, response) = try await URLSession.shared.data(for: disable)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let (_, offline) = try await URLSession.shared.data(from: try XCTUnwrap(URL(string: prefix + "/media.mp4")))
        XCTAssertEqual((offline as? HTTPURLResponse)?.statusCode, 503, "The remote origin must be unusable before local playback")
        handedOff = true
        return (engine, record, prefix)
    }

    func testDownloadedMP4PlaysWithOriginDisabledAndPersistsResumeAcrossPlayerRecreation() async throws {
        let (engine, record, _) = try await downloaded()
        defer { engine.shutdown() }
        let historyURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("history.json")
        let player = OfflinePlaybackModel(engine: engine, historyStorage: HistoryFileStorage(fileURL: historyURL))
        defer { player.stop() }
        player.play(record)
        try await waitUntil("local-only playback progression") { player.playback.seconds > 4.2 }
        XCTAssertTrue((player.playback.player.currentItem?.asset as? AVURLAsset)?.url.isFileURL == true)
        XCTAssertNil(player.playback.errorMessage)
        player.stop()
        let history = WatchHistoryModel(storage: HistoryFileStorage(fileURL: historyURL), providerId: "demo-v1")
        let episode = Episode(id: "demo-mp4", animeId: 101, number: 1, title: "Original Episode")
        XCTAssertGreaterThan(history.record(for: episode)?.positionMs ?? 0, 4_000)
        let recreated = OfflinePlaybackModel(engine: engine, historyStorage: HistoryFileStorage(fileURL: historyURL))
        defer { recreated.stop() }
        recreated.play(record)
        try await waitUntil("persisted offline resume") {
            recreated.playback.appliedResumeSeconds > 1 && recreated.playback.seconds > recreated.playback.appliedResumeSeconds + 0.5
        }
        XCTAssertNil(recreated.playback.errorMessage)
        print("Offline MP4 origin=503, local file progression=\(recreated.playback.seconds), resume=\(recreated.playback.appliedResumeSeconds)")
    }

    func testJourneyUsesLocalDownloadWithoutResolverAndFallsBackAfterDeletion() async throws {
        let (engine, record, _) = try await downloaded()
        defer { engine.shutdown() }
        let transport = OfflineRejectingTransport()
        let journey = JourneyModel(transport: transport, downloads: engine)
        defer { journey.leaveJourney() }
        journey.openAnime(101)
        try await waitUntil("initial failed metadata requests") { !journey.isLoadingEpisodes && !journey.detailsModel.isLoading }
        let requests = transport.count
        let episode = Episode(id: record.identity.episodeId, animeId: 101, number: record.episodeNumber, title: record.episodeTitle)
        journey.selectEpisode(episode)
        try await waitUntil("journey local playback") { journey.playback.seconds > 1 }
        XCTAssertEqual(transport.count, requests, "Offline selection must never resolve the provider")
        XCTAssertNil(journey.playback.errorMessage)
        journey.returnToEpisodes()
        XCTAssertGreaterThan(journey.history.record(for: episode)?.positionMs ?? 0, 0)
        XCTAssertEqual(journey.history.record(for: episode)?.title, "Original Offline Fixture")
        engine.delete(record: record)
        journey.selectEpisode(episode)
        try await waitUntil("online fallback after local deletion") { journey.resolutionError != nil }
        XCTAssertGreaterThan(transport.count, requests)
        XCTAssertNil(journey.playback.player.currentItem)
    }
}

private final class OfflineRejectingTransport: NSObject, CatalogCallbackTransport {
    private let lock = NSLock()
    private var requests = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    func post(request: CatalogHttpRequest, completion: CatalogHttpCompletion) -> CatalogCancellation {
        lock.lock(); requests += 1; lock.unlock()
        completion.complete(response: CatalogHttpResponse(status: 503, body: "{}"), error: nil)
        return OfflineNoopCancellation()
    }
}
private final class OfflineNoopCancellation: NSObject, CatalogCancellation { func cancel() {} }
