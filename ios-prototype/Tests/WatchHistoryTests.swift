import AVFoundation
import Foundation
import SharedCore
import XCTest
@testable import PlaybackPOC

@MainActor
final class WatchHistoryTests: XCTestCase {
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("history.json")
    }
    private func waitUntil(_ label: String, timeout: TimeInterval = 20, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out: \(label)")
    }
    private func openEpisode(_ model: JourneyModel) async throws {
        model.openAnime(101)
        try await waitUntil("demo episodes") { !model.isLoadingEpisodes && !model.detailsModel.isLoading }
        model.selectEpisode(try XCTUnwrap(model.episodes.first { $0.id == "demo-mp4" }))
    }

    func testAtomicStorageComparesAcrossInstancesAndPreservesMismatches() throws {
        let url = location()
        let first = HistoryFileStorage(fileURL: url)
        let second = HistoryFileStorage(fileURL: url)
        XCTAssertNil(try first.readSnapshot())
        XCTAssertTrue(try first.replaceSnapshot(expected: nil, updated: "first"))
        XCTAssertFalse(try second.replaceSnapshot(expected: nil, updated: "stale"))
        XCTAssertEqual(try second.readSnapshot(), "first")
        XCTAssertTrue(try second.replaceSnapshot(expected: "first", updated: "second"))
        XCTAssertEqual(try first.readSnapshot(), "second")
    }

    func testProgressSurvivesRepositoryRecreationAndSupportsMarking() throws {
        let url = location()
        var now: Int64 = 100_000
        let first = WatchHistoryModel(storage: HistoryFileStorage(fileURL: url), now: { now })
        let episode = Episode(id: "demo-mp4", animeId: 101, number: 1, title: "MP4 test pattern")
        XCTAssertEqual(first.begin(episode: episode, animeTitle: "Demo"), 0)
        now += 1_000
        first.sample(positionSeconds: 25, durationSeconds: 120, immediate: true)
        let recreated = WatchHistoryModel(storage: HistoryFileStorage(fileURL: url), now: { now })
        XCTAssertEqual(recreated.record(for: episode)?.positionMs, 25_000)
        XCTAssertEqual(recreated.continuing.count, 1)
        XCTAssertEqual(recreated.begin(episode: episode, animeTitle: "Demo"), 22)
        recreated.mark(episode, animeTitle: "Demo", watched: true)
        XCTAssertTrue(recreated.record(for: episode)?.completed == true)
        XCTAssertTrue(recreated.continuing.isEmpty)
        recreated.mark(episode, animeTitle: "Demo", watched: false)
        XCTAssertFalse(recreated.record(for: episode)?.completed ?? true)
        XCTAssertEqual(recreated.record(for: episode)?.positionMs, 0)
    }

    func testConfiguredCheckpointIntervalIsUsed() {
        var now: Int64 = 100_000
        let rules = WatchHistoryRules(completionPercent: 90, minDurationMs: 60_000,
                                      resumeRewindMs: 0, saveIntervalMs: 2_000)
        let model = WatchHistoryModel(rules: rules, now: { now })
        let episode = Episode(id: "demo-mp4", animeId: 101, number: 1, title: "MP4")
        _ = model.begin(episode: episode, animeTitle: "Demo")
        now += 1_999
        model.sample(positionSeconds: 2, durationSeconds: 120, immediate: false)
        XCTAssertEqual(model.record(for: episode)?.positionMs, 0)
        now += 1
        model.sample(positionSeconds: 2, durationSeconds: 120, immediate: false)
        XCTAssertEqual(model.record(for: episode)?.positionMs, 2_000)
    }

    func testPeriodicSaveAndImmediatePauseSaveUseOneRecord() {
        var now: Int64 = 100_000
        let model = WatchHistoryModel(now: { now })
        let episode = Episode(id: "demo-mp4", animeId: 101, number: 1, title: "MP4")
        _ = model.begin(episode: episode, animeTitle: "Demo")
        now += 9_000
        model.sample(positionSeconds: 9, durationSeconds: 120, immediate: false)
        XCTAssertEqual(model.record(for: episode)?.positionMs, 0)
        now += 1_000
        model.sample(positionSeconds: 10, durationSeconds: 120, immediate: false)
        XCTAssertEqual(model.record(for: episode)?.positionMs, 10_000)
        model.sample(positionSeconds: 4, durationSeconds: 120, immediate: true)
        XCTAssertEqual(model.record(for: episode)?.positionMs, 4_000, "Backward seeks must remain valid")
        XCTAssertEqual(model.records.count, 1)
    }

    func testCorruptAndFutureFilesRemainUntouchedAndReportErrors() throws {
        for document in ["invalid JSON", "{\"version\":99,\"records\":[]}"] {
            let url = location()
            let storage = HistoryFileStorage(fileURL: url)
            XCTAssertTrue(try storage.replaceSnapshot(expected: nil, updated: document))
            let model = WatchHistoryModel(storage: storage)
            XCTAssertNotNil(model.errorMessage)
            let episode = Episode(id: "demo-mp4", animeId: 101, number: 1, title: "MP4")
            _ = model.begin(episode: episode, animeTitle: "Demo")
            XCTAssertNotNil(model.errorMessage)
            XCTAssertEqual(try storage.readSnapshot(), document)
        }
    }

    func testRealPlayerPausesPersistsAndResumesAfterJourneyRecreation() async throws {
        let url = location()
        let first = JourneyModel(history: WatchHistoryModel(storage: HistoryFileStorage(fileURL: url)))
        try await openEpisode(first)
        try await waitUntil("first session progressed") { first.playback.seconds > 5 }
        first.playback.pause()
        let saved = try XCTUnwrap(first.history.records.first?.positionMs)
        XCTAssertGreaterThan(saved, 4_000)
        first.returnToEpisodes()
        first.leaveJourney()
        let second = JourneyModel(history: WatchHistoryModel(storage: HistoryFileStorage(fileURL: url)))
        defer { second.leaveJourney() }
        try await openEpisode(second)
        try await waitUntil("saved position restored before progression") { second.playback.appliedResumeSeconds > 1 }
        XCTAssertEqual(second.playback.appliedResumeSeconds, Double(saved) / 1_000 - 3, accuracy: 0.5)
        let resumed = second.playback.appliedResumeSeconds
        try await waitUntil("resumed player progressed") { second.playback.seconds > resumed + 0.5 && second.playback.player.timeControlStatus == .playing }
        print("Resumed persisted playback at \(resumed)s; advanced to \(second.playback.seconds)s")
    }

    func testBackgroundImmediatelyPersistsProgress() async throws {
        let url = location()
        let model = JourneyModel(history: WatchHistoryModel(storage: HistoryFileStorage(fileURL: url)))
        defer { model.leaveJourney() }
        try await openEpisode(model)
        try await waitUntil("playing before background") { model.playback.seconds > 1 }
        model.background()
        let restored = WatchHistoryModel(storage: HistoryFileStorage(fileURL: url))
        XCTAssertGreaterThan(restored.records.first?.positionMs ?? 0, 500)
        XCTAssertEqual(model.playback.player.rate, 0)
    }

    func testMarkingActiveEpisodeReleasesPlayerAndUnmarkedReplaySavesNewSession() async throws {
        let model = JourneyModel()
        defer { model.leaveJourney() }
        try await openEpisode(model)
        try await waitUntil("playing before explicit mark") { model.playback.seconds > 1 }
        let episode = try XCTUnwrap(model.selectedEpisode)
        model.markEpisode(episode, watched: true)
        XCTAssertNil(model.playback.player.currentItem)
        XCTAssertNil(model.selectedEpisode)
        XCTAssertEqual(model.path, [.details(101)])
        XCTAssertTrue(model.history.record(for: episode)?.completed == true)
        let markedGeneration = try XCTUnwrap(model.history.record(for: episode)?.generation)

        model.markEpisode(episode, watched: false)
        XCTAssertFalse(model.history.record(for: episode)?.completed ?? true)
        model.selectEpisode(episode)
        try await waitUntil("unmarked replay progressed") { model.playback.seconds > 1 }
        model.playback.pause()
        let replay = try XCTUnwrap(model.history.record(for: episode))
        XCTAssertGreaterThan(replay.generation, markedGeneration)
        XCTAssertGreaterThan(replay.positionMs, 500)
        XCTAssertFalse(replay.completed)
    }

}
